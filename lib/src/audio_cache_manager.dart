import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../handlers/hls_cache_handler.dart';
import '../handlers/mp3_cache_handler.dart';
import '../storage/cache_metadata_store.dart';
import '../models/cache_entry.dart';
import '../utils/aes_encryptor.dart';

class CacheException implements Exception {
  final String message;
  CacheException(this.message);
  @override
  String toString() => 'CacheException: $message';
}

class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager();
  // factory AudioCacheManager() => _instance;

  final Duration expirationDuration;
  final bool enableEncryption;
  final int maxCacheSize;
  bool isUserSubscribed;
  final String encryptionKey;

  final Mp3CacheHandler _mp3Handler;
  final HlsCacheHandler _hlsHandler;
  final CacheMetadataStore _metadataStore;
  bool _isInitialized = false; // Track initialization state

  AudioCacheManager({
    this.expirationDuration = const Duration(days: 30),
    this.enableEncryption = false,
    this.maxCacheSize = 2 * 1024 * 1024 * 1024, // 2GB
    this.isUserSubscribed = false,
    this.encryptionKey = 'your-32-byte-secure-key-here-1234',
  })  : _metadataStore = CacheMetadataStore(),
        _mp3Handler = Mp3CacheHandler(),
        _hlsHandler = HlsCacheHandler();

  Future<void> init() async {
    if (_isInitialized) return; // Prevent reinitialization
    await _metadataStore.init();
    await _cleanupExpiredCache();
    _isInitialized = true;
  }

  /// Caches a playlist of audio tracks for offline playback.
  /// [trackUrls] List of track URLs (MP3 or HLS).
  /// [playlistId] Unique identifier for the playlist.
  /// [onProgress] Optional callback for caching progress.
  Future<List<File?>> cachePlaylist(
      List<String> trackUrls,
      String playlistId, {
        Function(int completed, int total)? onProgress,
      }) async {
    if (!_isInitialized) await init(); // Ensure initialized
    final cachedFiles = <File?>[];
    try {
      final futures = <Future>[];
      for (int i = 0; i < trackUrls.length; i++) {
        final trackId = '$playlistId-track-$i';
        final isHls = trackUrls[i].endsWith('.m3u8');
        futures.add(getAudioFile(trackUrls[i], isHls: isHls, trackId: trackId).then((file) {
          if (file != null) {
            _metadataStore.save(CacheEntry(
              url: trackUrls[i],
              localPath: file.path,
              cachedAt: DateTime.now(),
              playlistId: playlistId,
            ));
          }
          cachedFiles.add(file);
          onProgress?.call(i + 1, trackUrls.length);
        }).catchError((e) {
          print('Error caching track $trackId: $e'); // Updated to use AppLogger
          cachedFiles.add(null);
        }));
      }
      await Future.wait(futures);
      await _cleanupExpiredCache();
      return cachedFiles;
    } catch (e) {
      throw CacheException('Failed to cache playlist $playlistId: $e');
    }
  }

  /// Retrieves or caches an audio file.
  /// [url] The remote URL of the audio file.
  /// [isHls] Whether the file is an HLS stream.
  /// [trackId] Optional unique identifier for the track.
  Future<File?> getAudioFile(String url, {bool isHls = false, String? trackId}) async {
    if (!_isInitialized) await init(); // Ensure initialized
    try {
      final now = DateTime.now();
      final entry = await _metadataStore.get(url);

      if (entry != null && now.difference(entry.cachedAt) < expirationDuration) {
        final file = File(entry.localPath);
        if (!file.existsSync()) {
          await _metadataStore.delete(url);
          return await getAudioFile(url, isHls: isHls, trackId: trackId);
        }
        if (isUserSubscribed && enableEncryption) {
          try {
            return await _decryptFile(file);
          } catch (e) {
            throw CacheException('Decryption failed for $url: $e');
          }
        }
        return file;
      }

      File? downloadedFile;
      if (isHls) {
        downloadedFile = await _hlsHandler.download(
          url,
          encrypt: enableEncryption && isUserSubscribed,
          encryptionKey: encryptionKey,
          trackId: trackId ?? url.hashCode.toString(),
        );
      } else {
        downloadedFile = await _mp3Handler.download(
          url,
          encrypt: enableEncryption && isUserSubscribed,
          encryptionKey: encryptionKey,
          trackId: trackId ?? url.hashCode.toString(),
        );
      }

      if (downloadedFile == null) {
        throw CacheException('Download failed for $url');
      }

      await _metadataStore.save(CacheEntry(
        url: url,
        localPath: downloadedFile.path,
        cachedAt: now,
        playlistId: null,
      ));

      return downloadedFile;
    } catch (e) {
      throw CacheException('Error retrieving audio file $url: $e');
    }
  }

  Future<File> _decryptFile(File file) async {
    final data = await file.readAsBytes();
    final aes = AESHelper(encryptionKey);
    final decryptedData = aes.decryptData(data);
    final decryptedPath = '${file.path}.dec';
    final decryptedFile = File(decryptedPath);
    await decryptedFile.writeAsBytes(decryptedData);
    return decryptedFile;
  }

  Future<void> _cleanupExpiredCache() async {
    final allEntries = await _metadataStore.getAll();
    final now = DateTime.now();
    final dir = await getTemporaryDirectory();
    int totalSize = await _calculateDirectorySize(dir);

    // Delete expired files
    for (final entry in allEntries) {
      if (now.difference(entry.cachedAt) > expirationDuration) {
        try {
          final file = File(entry.localPath);
          if (file.existsSync()) {
            totalSize -= file.lengthSync();
            file.deleteSync();
          }
          await _metadataStore.delete(entry.url);
        } catch (_) {}
      }
    }

    // Enforce size limit with LRU policy
    if (totalSize > maxCacheSize) {
      final files = dir.listSync(recursive: true).whereType<File>().toList();
      files.sort((a, b) => a.statSync().accessed.compareTo(b.statSync().accessed));
      for (final file in files) {
        if (totalSize <= maxCacheSize) break;
        try {
          final fileSize = file.lengthSync();
          file.deleteSync();
          totalSize -= fileSize;
          final fileName = file.path.split('/').last.split('.').first;
          await _metadataStore.delete(fileName);
        } catch (_) {}
      }
    }
  }

  Future<int> _calculateDirectorySize(Directory dir) async {
    int size = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        size += entity.statSync().size;
      }
    }
    return size;
  }

  /// Clears all cached files and metadata.
  Future<void> clearCache() async {
    try {
      await _metadataStore.clear();
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory('${dir.path}/audio_cache');
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      throw CacheException('Failed to clear cache: $e');
    }
  }

  /// Disposes the cache manager, closing the metadata store.
  Future<void> dispose() async {
    if (_isInitialized) {
      await _metadataStore.dispose();
      _isInitialized = false;
    }
  }
}
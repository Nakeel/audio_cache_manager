import 'dart:io';
import 'dart:typed_data';

import 'package:audio_cache_manager/handlers/hls_cache_handler.dart';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/handlers/mp3_cache_handler.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart' show Uuid;


class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;

  AudioCacheManager._internal();

  late String _cacheDirPath;
  late CacheMetadataStore _metadataStore;
  late LocalProxyServer _proxyServer;
  // No direct instance of AESHelper needed if all methods are static
  late HlsCacheHandler _hlsCacheHandler;

  bool _isInitialized = false;
  Duration _expirationDuration = const Duration(days: 30);
  int _maxCacheSizeBytes = 500 * 1024 * 1024; // Default 500 MB
  bool _enableEncryption = false;

  void configure({
    Duration? expirationDuration,
    int? maxCacheSizeBytes,
    bool? enableEncryption,
  }) {
    if (_isInitialized) {
      AppLogger.warning('AudioCacheManager is already initialized. Configuration changes will not take effect until a restart.', name: 'AudioCacheManager');
    }
    _expirationDuration = expirationDuration ?? _expirationDuration;
    _maxCacheSizeBytes = maxCacheSizeBytes ?? _maxCacheSizeBytes;
    _enableEncryption = enableEncryption ?? _enableEncryption;
    AppLogger.info('AudioCacheManager configured: expirationDuration=$_expirationDuration, maxCacheSizeBytes=${_maxCacheSizeBytes / (1024 * 1024)} MB, enableEncryption=$_enableEncryption', name: 'AudioCacheManager');
  }

  Future<void> init() async {
    if (_isInitialized) {
      AppLogger.warning('AudioCacheManager already initialized.', name: 'AudioCacheManager');
      return;
    }

    _cacheDirPath = await _getCacheDirPath();
    _metadataStore = CacheMetadataStore();
    // Pass metadataStore to LocalProxyServer constructor
    _proxyServer = LocalProxyServer(cacheDirPath: _cacheDirPath, metadataStore: _metadataStore);
    _hlsCacheHandler = HlsCacheHandler();

    await _metadataStore.init();
    await _proxyServer.start();
    // Removed _encryptionHelper.init() - AESHelper is static
    AppLogger.info('EncryptionHelper (AESHelper) does not require explicit initialization as it uses static methods.', name: 'AudioCacheManager');


    // Perform initial cleanup
    await _cleanupCache();

    _isInitialized = true;
    AppLogger.info('AudioCacheManager initialized.', name: 'AudioCacheManager');
  }

  Future<bool> isAudioCached(String trackId) async {
    final entry = await _metadataStore.get(trackId);
    if (entry == null) {
      AppLogger.info('Track $trackId not found in cache metadata.', name: 'APP');
      return false;
    }

    final bool exists = await entry.cacheFileEntity.exists();
    if (!exists) {
      AppLogger.warning('Track $trackId metadata exists, but file/directory ${entry.cacheFileEntity.path} does not exist. Removing metadata.', name: 'APP');
      await _metadataStore.delete(trackId);
      return false;
    }
    return true;
  }

  /// Returns information about the current cache state.
  Future<Map<String, dynamic>> getCacheInfo() async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager not initialized when calling getCacheInfo.', name: 'AudioCacheManager');
      return {'cachedCount': 0, 'currentSize': 0};
    }
    final allEntries = await _metadataStore.getAll();
    final currentSize = _metadataStore.getCurrentCacheSize();
    return {
      'cachedCount': allEntries.length,
      'currentSize': currentSize,
    };
  }

  Future<String?> cacheAudio(
      String url,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }

    final bool cachedAndValid = await isAudioCached(trackId);
    if (cachedAndValid) {
      final existingEntry = await _metadataStore.get(trackId);
      if (existingEntry != null) {
        // Update timestamp for LRU policy
        await _metadataStore.save(CacheEntry(
          trackId: existingEntry.trackId,
          originalUrl: existingEntry.originalUrl,
          filePath: existingEntry.filePath,
          timestamp: DateTime.now(),
          fileSize: existingEntry.fileSize,
          isEncrypted: existingEntry.isEncrypted,
          etag: existingEntry.etag,
          lastModified: existingEntry.lastModified,
          contentType: existingEntry.contentType,
          proxyUrl: existingEntry.proxyUrl,
          isHls: existingEntry.isHls,
          hlsLocalPath: existingEntry.hlsLocalPath,
        ));
        AppLogger.info('Track $trackId already cached and valid. Returning playback URL.', name: 'APP');
        return getPlaybackUrl(trackId);
      }
    }

    final uri = Uri.parse(url);
    final String tempFileName = '${const Uuid().v4()}.tmp';
    final String tempFilePath = p.join(_cacheDirPath, tempFileName);
    final String finalFileName = const Uuid().v4();

    try {
      if (uri.path.endsWith('.m3u8')) {
        AppLogger.info('Track $trackId is HLS. Attempting to cache HLS stream.', name: 'APP');

        final String? localHlsPath = await _hlsCacheHandler.cacheHls(
          url,
          _cacheDirPath,
          trackId,
          onProgress: onProgress,
        );

        if (localHlsPath == null) {
          AppLogger.error('Failed to cache HLS stream: $url', name: 'APP');
          return null;
        }

        final newEntry = CacheEntry(
          trackId: trackId,
          originalUrl: url,
          filePath: '',
          timestamp: DateTime.now(),
          fileSize: 0,
          isEncrypted: false,
          etag: '',
          lastModified: '',
          contentType: 'application/x-mpegURL',
          proxyUrl: '', // HLS will be played directly from local path
          isHls: true,
          hlsLocalPath: localHlsPath,
        );
        await _metadataStore.save(newEntry);
        await _cleanupCache();

        AppLogger.info('Cached HLS $trackId. Local manifest: $localHlsPath', name: 'APP');
        return localHlsPath;

      } else {
        AppLogger.info('Downloading MP3 from $url to temporary file: $tempFilePath', name: 'APP');
        final response = await http.Client().send(http.Request('GET', uri));

        if (response.statusCode != 200) {
          throw Exception('Failed to download audio: ${response.statusCode}');
        }

        final file = File(tempFilePath);
        final sink = file.openWrite();
        int receivedBytes = 0;
        final int? totalBytes = response.contentLength;

        await for (var chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes??0);
        }
        await sink.close();

        final etag = response.headers['etag'] ?? '';
        final lastModified = response.headers['last-modified'] ?? '';
        final contentType = response.headers['content-type'] ?? 'application/octet-stream';

        Uint8List audioBytes = await file.readAsBytes();
        AppLogger.info('Downloaded MP3 size: ${audioBytes.length} bytes', name: 'APP');

        bool currentEncryptionStatus = _enableEncryption;
        if (currentEncryptionStatus) {
          AppLogger.info('Encrypting audio for $url', name: 'APP');
          audioBytes = AESHelper.encrypt(audioBytes); // Changed to static AESHelper.encrypt
          AppLogger.info('Encryption complete for $url', name: 'APP');
        } else {
          AppLogger.info('Encryption disabled for $url', name: 'APP');
        }

        final String finalFilePath = p.join(_cacheDirPath, finalFileName);
        final File finalFile = File(finalFilePath);
        await finalFile.writeAsBytes(audioBytes);
        await file.delete();

        AppLogger.info('MP3 $finalFileName saved to $finalFilePath, size: ${audioBytes.length} bytes (Original: $totalBytes bytes). Encrypted: $currentEncryptionStatus', name: 'APP');

        final newEntry = CacheEntry(
          trackId: trackId,
          originalUrl: url,
          filePath: finalFilePath,
          timestamp: DateTime.now(),
          fileSize: audioBytes.length,
          isEncrypted: currentEncryptionStatus,
          etag: etag,
          lastModified: lastModified,
          contentType: contentType,
          proxyUrl: _proxyServer.getProxyUrl(trackId), // Use new getProxyUrl
        );
        await _metadataStore.save(newEntry);
        await _cleanupCache();

        return _proxyServer.getProxyUrl(trackId);
      }
    } catch (e, st) {
      AppLogger.error('Error caching audio $url: $e', error: e, stackTrace: st, name: 'AudioCacheManager');
      if (await File(tempFilePath).exists()) {
        await File(tempFilePath).delete();
      }
      return null;
    }
  }

  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }

    final entry = await _metadataStore.get(trackId);
    if (entry == null) {
      AppLogger.warning('Track $trackId not found in cache.', name: 'APP');
      return null;
    }

    if (entry.isHls) {
      if (entry.hlsLocalPath == null || !await Directory(entry.hlsLocalPath!).exists()) {
        AppLogger.warning('HLS local path for $trackId is invalid or missing. Clearing metadata.', name: 'APP');
        await _metadataStore.delete(trackId);
        return null;
      }
      AppLogger.info('Track $trackId is HLS. Returning local manifest: ${entry.hlsLocalPath}', name: 'APP');
      return entry.hlsLocalPath;
    } else {
      if (!await File(entry.filePath).exists()) {
        AppLogger.warning('File for $trackId does not exist at ${entry.filePath}. Clearing metadata.', name: 'APP');
        await _metadataStore.delete(trackId);
        return null;
      }
      AppLogger.info('Track $trackId is MP3. Returning proxy URL: ${entry.proxyUrl}', name: 'APP');
      return entry.proxyUrl;
    }
  }

  Future<void> clearAudioCache(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return;
    }

    final entry = await _metadataStore.get(trackId);
    if (entry != null) {
      if (entry.isHls) {
        AppLogger.info('Clearing HLS cache for $trackId...', name: 'APP');
        await _hlsCacheHandler.deleteCachedHls(entry.hlsLocalPath!);
      } else {
        AppLogger.info('Clearing MP3 cache for $trackId...', name: 'APP');
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
          AppLogger.info('Deleted cached file: ${file.path}', name: 'APP');
        }
      }
      await _metadataStore.delete(trackId);
      AppLogger.info('Cache for $trackId cleared.', name: 'APP');
    } else {
      AppLogger.info('No cache found for $trackId to clear.', name: 'APP');
    }
  }

  Future<void> clearAllCache() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return;
    }

    AppLogger.info('Clearing all audio cache...', name: 'APP');
    final allEntries = await _metadataStore.getAll();
    for (final entry in allEntries) {
      if (entry.isHls) {
        await _hlsCacheHandler.deleteCachedHls(entry.hlsLocalPath!);
      } else {
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    await _metadataStore.clear();
    AppLogger.info('All audio cache cleared.', name: 'APP');
  }

  Future<void> _cleanupCache() async {
    AppLogger.info('Performing cache cleanup...', name: 'APP');
    final allEntries = await _metadataStore.getAll();
    final now = DateTime.now();

    allEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    List<CacheEntry> entriesToDelete = [];

    for (final entry in allEntries) {
      final bool existsOnDisk = await entry.cacheFileEntity.exists();
      if (!existsOnDisk) {
        AppLogger.warning('File/directory for ${entry.trackId} not found on disk. Marking for deletion.', name: 'APP');
        entriesToDelete.add(entry);
      } else if (now.difference(entry.timestamp) > _expirationDuration) {
        AppLogger.info('Entry for ${entry.trackId} expired. Marking for deletion.', name: 'APP');
        entriesToDelete.add(entry);
      }
    }

    // Recalculate currentTotalSize after marking for deletion based on existence/expiry
    int currentTotalSize = _metadataStore.getCurrentCacheSize();

    for (final entry in allEntries) {
      // Only consider for eviction if not already marked for deletion and still over size limit
      if (!entriesToDelete.contains(entry) && currentTotalSize > _maxCacheSizeBytes) {
        AppLogger.info('Evicting ${entry.trackId} due to cache size limit. Current size: ${currentTotalSize / (1024 * 1024)} MB', name: 'APP');
        entriesToDelete.add(entry);
        currentTotalSize -= entry.fileSize; // Adjust size only for files being newly added to eviction list
      }
    }

    for (final entry in entriesToDelete) {
      if (entry.isHls) {
        AppLogger.info('Deleting expired/overflow HLS directory: ${entry.hlsLocalPath}', name: 'APP');
        await _hlsCacheHandler.deleteCachedHls(entry.hlsLocalPath!);
      } else {
        AppLogger.info('Deleting expired/overflow MP3 file: ${entry.filePath}', name: 'APP');
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await _metadataStore.delete(entry.trackId);
    }
    AppLogger.info('Cache cleanup complete. Current size: ${_metadataStore.getCurrentCacheSize() / (1024 * 1024)} MB', name: 'APP');
  }

  Future<String> _getCacheDirPath() async {
    final Directory appCacheDir = await getTemporaryDirectory();
    final cacheDir = Directory(p.join(appCacheDir.path, 'audio_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  void dispose() {
    if (_isInitialized) {
      _proxyServer.stop();
      _metadataStore.close();
      _isInitialized = false;
      AppLogger.info('AudioCacheManager disposed.', name: 'AudioCacheManager');
    }
  }
}
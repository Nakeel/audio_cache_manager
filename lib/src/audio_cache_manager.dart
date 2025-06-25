import 'dart:collection';
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../handlers/mp3_cache_handler.dart';
import '../storage/cache_metadata_store.dart';
import '../models/cache_entry.dart';
import '../utils/aes_encryptor.dart';
import 'package:path/path.dart' as p;
import 'dart:typed_data';

/// Custom cache manager for music tracks, supporting playlists, HLS, and encryption.
/// It orchestrates downloads, storage, local proxy serving, and metadata management.
class AudioCacheManager {
  // Singleton instance
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal(); // Private constructor for singleton

  // Dependencies
  final CacheMetadataStore _metadataStore = CacheMetadataStore();
  final LocalProxyServer _localProxyServer = LocalProxyServer();
  final Mp3CacheHandler _mp3Handler = Mp3CacheHandler();
  final Dio _dio = Dio(); // Dedicated Dio instance for internal downloads

  // Configuration - now `late final` and initialized in `init()`
  late final Duration expirationDuration;
  late final int maxCacheSizeBytes;
  late final String encryptionKey; // THIS IS A PLACEHOLDER - LOAD SECURELY

  /// Tracks subscription status. This should be set externally by your Auth/Subscription BLoC.
  bool isUserSubscribed = false;

  // Internal flag to ensure init() is called only once successfully
  bool _isInitialized = false;

  // Base directory for all cached files
  late Directory _baseCacheDir;

  /// Configures the cache manager with provided settings.
  /// Must be called before `init()` if custom settings are desired.
  /// If not called, `init()` will use its own defaults.
  void configure({
    Duration? expirationDuration,
    int? maxCacheSizeBytes,
    String? encryptionKey,
  }) {
    // Initialize late final fields directly
    this.expirationDuration = expirationDuration ?? const Duration(days: 30);
    this.maxCacheSizeBytes = maxCacheSizeBytes ?? 2 * 1024 * 1024 * 1024; // 2GB
    this.encryptionKey = encryptionKey ?? 'your-32-byte-secure-key-here-1234'; // DEMO ONLY: Replace this!

    // Set the encryption key for AESHelper immediately after configuration
    AESHelper.setEncryptionKey(this.encryptionKey);
  }

  /// Initializes the cache manager, metadata store, and local proxy server.
  /// Must be called once before using the cache manager.
  Future<void> init() async {
    if (_isInitialized) {
      print('AudioCacheManager already initialized. Skipping init().');
      return;
    }

    // Ensure configuration is set. If configure() wasn't called externally, call it now with defaults.
    try {
      // Attempt to access a late final field to check if configure() has run
      // This will throw if not initialized, caught by the outer try/catch
      // A more explicit flag in configure() is generally better, but this works for late final.
      if (this.encryptionKey == null) { // Simple check if configured
        configure(); // Apply defaults if not explicitly configured
      }
    } catch (_) {
      configure(); // Apply defaults if not explicitly configured
    }


    // 1. Initialize base cache directory
    _baseCacheDir = await getApplicationDocumentsDirectory(); // For persistent cache
    _baseCacheDir = Directory(p.join(_baseCacheDir.path, 'audio_cache'));
    if (!await _baseCacheDir.exists()) {
      await _baseCacheDir.create(recursive: true);
    }
    print('AudioCacheManager: Base cache directory: ${_baseCacheDir.path}');

    // 2. Initialize metadata store (Hive)
    await _metadataStore.init();

    // 3. Initialize and start the local proxy server
    await _localProxyServer.init(
      getCacheEntry: (trackId) async {
        // The proxy server requests metadata for specific content by trackId
        return _metadataStore.get(trackId);
      },
      isUserSubscribed: () => isUserSubscribed,
    );

    // 4. Perform initial cache cleanup on startup
    await _cleanupCache();

    _isInitialized = true;
    print('AudioCacheManager initialized and ready.');
  }

  /// Downloads and caches an audio file (MP3 or HLS).
  /// Returns the trackId if successful, null otherwise.
  Future<String?> cacheAudio(
      String originalUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
        bool isHls = false,
      }) async {
    // Ensure manager is initialized before any operation
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    try {
      // Check if already cached and still valid
      final existingEntry = await _metadataStore.get(trackId);
      if (existingEntry != null &&
          await (existingEntry.isHls ? Directory(existingEntry.localPath).exists() : File(existingEntry.localPath).exists()) &&
          DateTime.now().difference(existingEntry.cachedAt) < expirationDuration) {
        print('Audio $trackId already cached and valid. Path: ${existingEntry.localPath}');
        // Update lastAccessedAt as caching implies access
        existingEntry.updateAccessedTime();
        await existingEntry.save();
        return trackId;
      }

      final bool shouldEncrypt = isUserSubscribed; // Encrypt if user is subscribed

      String? finalLocalPath;
      int fileSize = 0;

      if (isHls) {
        // Handle HLS download and manifest rewriting
        final result = await _downloadHls(originalUrl, trackId, shouldEncrypt, onProgress);
        if (result != null) {
          finalLocalPath = result['localPath'];
          fileSize = result['fileSize'];
        }
      } else {
        // Handle MP3 download
        final result = await _downloadMp3(originalUrl, trackId, shouldEncrypt, onProgress);
        if (result != null) {
          finalLocalPath = result['localPath'];
          fileSize = result['fileSize'];
        }
      }

      if (finalLocalPath != null) {
        final newEntry = CacheEntry(
          trackId: trackId, // Store trackId in the CacheEntry
          url: originalUrl, // Original URL
          localPath: finalLocalPath, // Path to the file or HLS directory
          cachedAt: DateTime.now(),
          lastAccessedAt: DateTime.now(), // Set initial last accessed
          fileSize: fileSize,
          isEncrypted: shouldEncrypt,
          isHls: isHls,
          // Add optional title/artist here if available
        );
        await _metadataStore.save(newEntry); // Save with trackId as key
        print('Cached audio $trackId: ${newEntry.url} to ${newEntry.localPath}, Encrypted: $shouldEncrypt, Size: $fileSize bytes.');
        return trackId;
      }
      return null;
    } catch (e) {
      print('Error in cacheAudio for $trackId: $e');
      // TODO: Log specific errors and perform cleanup of partial downloads
      await _cleanupPartialDownload(trackId, isHls);
      return null;
    } finally {
      await _cleanupCache(); // Enforce limits after each caching operation
    }
  }

  /// Helper to clean up a partial download if an error occurs.
  Future<void> _cleanupPartialDownload(String trackId, bool isHls) async {
    final entry = await _metadataStore.get(trackId); // Get by trackId
    if (entry != null) {
      if (isHls) {
        final dir = Directory(entry.localPath);
        if (await dir.exists()) await dir.delete(recursive: true);
      } else {
        final file = File(entry.localPath);
        if (await file.exists()) await file.delete();
      }
      await _metadataStore.delete(trackId); // Delete by trackId
      print('Cleaned up partial download for $trackId');
    }
  }

  /// Downloads and saves an MP3 file.
  Future<Map<String, dynamic>?> _downloadMp3(
      String url,
      String trackId,
      bool shouldEncrypt,
      Function(int received, int total)? onProgress,
      ) async {
    final Uint8List? downloadedBytes = await _mp3Handler.downloadMp3Bytes(url, onProgress: onProgress);
    if (downloadedBytes == null) return null;

    Uint8List bytesToSave = downloadedBytes;
    String fileName = '$trackId.mp3';

    if (shouldEncrypt) {
      bytesToSave = AESHelper.encryptData(downloadedBytes);
      fileName = '$trackId.mp3.enc'; // Add .enc extension for encrypted files
      print('MP3 content encrypted for $trackId.');
    }

    final File outputFile = File(p.join(_baseCacheDir.path, fileName));
    if (await outputFile.exists()) await outputFile.delete(); // Ensure clean slate
    await outputFile.writeAsBytes(bytesToSave);

    final fileSize = await outputFile.length();
    print('MP3 $trackId saved to ${outputFile.path}, size: $fileSize bytes.');
    return {
      'localPath': outputFile.path,
      'fileSize': fileSize,
    };
  }

  /// Downloads HLS manifest and segments, rewriting the manifest.
  Future<Map<String, dynamic>?> _downloadHls(
      String m3u8Url,
      String trackId,
      bool shouldEncrypt,
      Function(int received, int total)? onProgress,
      ) async {
    final String trackCacheDirPath = p.join(_baseCacheDir.path, trackId);
    final Directory trackDir = Directory(trackCacheDirPath);

    if (await trackDir.exists()) {
      await trackDir.delete(recursive: true); // Clean up any existing content
    }
    await trackDir.create(recursive: true);
    print('Created HLS cache directory: ${trackDir.path}');

    // 1. Download Master M3U8 Manifest
    final Response<String> manifestResponse = await _dio.get(
      m3u8Url,
      options: Options(responseType: ResponseType.plain),
    );
    final String masterM3u8Content = manifestResponse.data!;
    final String masterM3u8FileName = p.basename(m3u8Url);
    final File localMasterM3u8File = File(p.join(trackDir.path, masterM3u8FileName));
    await localMasterM3u8File.writeAsString(masterM3u8Content);
    print('HLS master manifest downloaded: ${localMasterM3u8File.path}');

    // 2. Parse Manifests and Collect All Segment/Sub-playlist URLs
    Set<String> allMediaUrlsToDownload = {}; // Use Set to avoid duplicates
    Queue<String> manifestsToParse = Queue();
    manifestsToParse.add(m3u8Url); // Start with the master manifest URL

    // Keep track of downloaded manifests to avoid infinite loops with circular references
    Set<String> downloadedManifests = {};

    while (manifestsToParse.isNotEmpty) {
      final currentManifestUrl = manifestsToParse.removeFirst();
      if (downloadedManifests.contains(currentManifestUrl)) {
        continue; // Already processed this manifest
      }
      downloadedManifests.add(currentManifestUrl);

      String currentManifestContent;
      // If it's the master manifest, use the already downloaded content.
      // Otherwise, fetch sub-manifest.
      if (currentManifestUrl == m3u8Url) {
        currentManifestContent = masterM3u8Content;
      } else {
        try {
          final subManifestResponse = await _dio.get(
            currentManifestUrl,
            options: Options(responseType: ResponseType.plain),
          );
          currentManifestContent = subManifestResponse.data!;
          // Save sub-manifest locally for proxy to serve (unmodified)
          final subM3u8FileName = p.basename(currentManifestUrl);
          final File localSubM3u8File = File(p.join(trackDir.path, subM3u8FileName));
          await localSubM3u8File.writeAsString(currentManifestContent);
          print('Downloaded sub-manifest: ${localSubM3u8File.path}');
        } on DioException catch (e) {
          print('Error downloading sub-manifest $currentManifestUrl: ${e.message}');
          continue; // Skip this manifest if download fails
        }
      }

      final lines = currentManifestContent.split('\n');
      final baseUri = Uri.parse(currentManifestUrl);

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          final resolvedUrl = baseUri.resolve(trimmedLine).toString();
          if (resolvedUrl.endsWith('.m3u8') && !downloadedManifests.contains(resolvedUrl)) {
            // Found a new sub-playlist, add to queue for parsing
            manifestsToParse.add(resolvedUrl);
          } else if (resolvedUrl.endsWith('.ts') || resolvedUrl.contains('.mp4') || resolvedUrl.contains('.aac')) {
            // Found a media segment
            allMediaUrlsToDownload.add(resolvedUrl);
          }
        }
      }
    }
    print('Found ${allMediaUrlsToDownload.length} unique media segments/playlists to download.');

    // 3. Download and Encrypt all Media Segments
    int downloadedCount = 0;
    int totalItems = allMediaUrlsToDownload.length;
    List<Future<void>> downloadFutures = [];

    for (final mediaUrl in allMediaUrlsToDownload) {
      downloadFutures.add(() async {
        final String mediaFileName = p.basename(mediaUrl);
        final String localMediaPath = p.join(trackDir.path, mediaFileName);

        try {
          final Response<Uint8List> mediaResponse = await _dio.get<Uint8List>(
            mediaUrl,
            options: Options(responseType: ResponseType.bytes),
            onReceiveProgress: (received, total) {
              // This progress is per-segment. Aggregate it if you need overall progress.
            },
          );

          if (mediaResponse.statusCode == 200 && mediaResponse.data != null) {
            Uint8List bytesToSave = mediaResponse.data!;
            if (shouldEncrypt) {
              bytesToSave = AESHelper.encryptData(mediaResponse.data!);
              print('Encrypted segment: $mediaFileName');
            }
            await File(localMediaPath).writeAsBytes(bytesToSave);
            downloadedCount++;
            if (onProgress != null) {
              // Report overall progress for all segments/files
              onProgress(downloadedCount, totalItems);
            }
          } else {
            print('Failed to download media $mediaUrl. Status: ${mediaResponse.statusCode}');
          }
        } on DioException catch (e) {
          print('DioError downloading media $mediaUrl: ${e.message}');
        } catch (e) {
          print('Error downloading media $mediaUrl: $e');
        }
      }()); // Immediately call the async function
    }
    await Future.wait(downloadFutures);
    print('All HLS media segments downloaded and processed for track $trackId.');

    // 4. Rewrite Master M3U8 and all Sub-M3U8s to point to Local Proxy Server
    // This is crucial for just_audio to request content from our proxy.
    // We iterate through all manifests we downloaded and rewrite them.
    final List<File> localManifestFiles = trackDir.listSync(recursive: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.m3u8'))
        .toList();

    for (final localManifestFile in localManifestFiles) {
      String currentManifestContent = await localManifestFile.readAsString();

      // We need to resolve URLs relative to the original source manifest URL,
      // not the local file system path, for accurate replacement.
      // This is complex. For simplicity, let's assume we replace based on actual downloaded URLs.
      // A more robust solution might involve parsing the manifest tree fully.

      currentManifestContent = currentManifestContent.split('\n').map((line) {
        final trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          // Attempt to find a media file or sub-playlist name in the line
          final fileNameMatch = RegExp(r'(.*)\.(?:ts|m3u8|mp4|aac)(\?.*)?$').firstMatch(trimmedLine);
          if (fileNameMatch != null) {
            final fileName = p.basename(trimmedLine.split('?')[0]); // Get filename without query params
            if (trimmedLine.endsWith('.m3u8')) {
              // This is a sub-playlist. It should also be proxied.
              return _localProxyServer.getHlsPlaylistProxyUrl(trackId, fileName);
            } else {
              // This is a media segment.
              return _localProxyServer.getHlsSegmentProxyUrl(trackId, fileName);
            }
          }
        }
        return line; // Return original line if not a URL to replace
      }).join('\n');

      // Overwrite the original local manifest file with the rewritten content
      await localManifestFile.writeAsString(currentManifestContent);
      print('Rewritten HLS manifest saved: ${localManifestFile.path}');
    }


    // Calculate total size of the HLS directory
    final int totalHlsSize = await _calculateDirectorySize(trackDir);
    print('HLS track $trackId total cached size: $totalHlsSize bytes.');

    return {
      'localPath': trackDir.path, // Store path to the HLS track directory
      'fileSize': totalHlsSize,
    };
  }

  /// Gets the playback URL for a cached audio track.
  /// Returns a local proxy URL for HLS and encrypted MP3s, or a direct file path for unencrypted MP3s.
  /// Returns null if the track is not cached or invalid.
  Future<String?> getPlaybackUrl(String trackId) async {
    // Ensure manager is initialized
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final CacheEntry? entry = await _metadataStore.get(trackId); // Get by trackId

    if (entry == null) {
      print('Track $trackId not found in cache metadata.');
      return null;
    }

    // Verify files/directories exist on disk
    final bool filesExist = entry.isHls
        ? await Directory(entry.localPath).exists()
        : await File(entry.localPath).exists();

    if (!filesExist) {
      print('Files for $trackId missing on disk. Cleaning up metadata.');
      await _metadataStore.delete(trackId); // Clean up stale metadata
      return null;
    }

    // Update last accessed time for LRU
    entry.updateAccessedTime();
    await entry.save(); // Save changes to Hive

    if (entry.isHls) {
      // Return the URL that points to our local proxy server for the master playlist
      final String masterM3u8FileName = p.basename(entry.url); // Use original URL's basename
      return _localProxyServer.getHlsPlaylistProxyUrl(trackId, masterM3u8FileName);
    } else {
      // Return proxy URL if encrypted, else direct file path
      return entry.isEncrypted ? _localProxyServer.getMp3ProxyUrl(trackId) : entry.localPath;
    }
  }

  /// Checks if a track is present and valid in the cache.
  Future<bool> isAudioCached(String trackId) async {
    // Ensure manager is initialized
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return false;
    }

    final entry = await _metadataStore.get(trackId); // Get by trackId
    if (entry == null) return false;

    // Check if the actual files exist and are within expiration
    final bool filesExist = entry.isHls
        ? await Directory(entry.localPath).exists()
        : await File(entry.localPath).exists();

    final bool notExpired = DateTime.now().difference(entry.cachedAt) < expirationDuration;

    return filesExist && notExpired;
  }

  /// Clears a specific track from cache (files and metadata).
  Future<void> clearAudioCache(String trackId) async {
    // Ensure manager is initialized
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return;
    }

    final entry = await _metadataStore.get(trackId); // Get by trackId
    if (entry != null) {
      await _deleteCachedItem(entry);
      print('Cleared cache for track: $trackId');
    } else {
      print('Track $trackId not found in cache to clear.');
    }
  }

  /// Clears all cached files and metadata.
  Future<void> clearAllCache() async {
    // Ensure manager is initialized
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return;
    }

    print('Clearing all cache (files and metadata)...');
    await _metadataStore.clear(); // Clear all metadata from Hive

    if (await _baseCacheDir.exists()) {
      try {
        await _baseCacheDir.delete(recursive: true);
        await _baseCacheDir.create(recursive: true); // Recreate empty directory
        print('All cached files deleted from disk.');
      } catch (e) {
        print('Error deleting base cache directory: $e');
      }
    }
    print('All custom cache cleared.');
  }

  /// Enforce cache size and duration limits.
  Future<void> _cleanupCache() async {
    // Ensure manager is initialized (implicitly, called from init or after init checks)
    final allEntries = await _metadataStore.getAll();
    final now = DateTime.now();

    // 1. Remove expired files first
    for (final entry in allEntries) {
      if (now.difference(entry.cachedAt) > expirationDuration) {
        print('Deleting expired item: ${entry.trackId} (cached at ${entry.cachedAt})');
        await _deleteCachedItem(entry);
      }
    }

    // Recalculate size after expiration cleanup
    int currentTotalSize = _metadataStore.getCurrentCacheSize();

    // 2. Enforce size limit (LRU - Least Recently Used)
    if (currentTotalSize > maxCacheSizeBytes) {
      final List<CacheEntry> sortedItems = await _metadataStore.getAll(); // Get fresh list after expiration
      sortedItems.sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt)); // Sort by oldest access

      for (final entry in sortedItems) {
        if (currentTotalSize <= maxCacheSizeBytes) break; // Stop if under limit
        print('Deleting LRU item: ${entry.trackId} (Last accessed: ${entry.lastAccessedAt}, Current size: ${currentTotalSize / (1024 * 1024)} MB)');
        await _deleteCachedItem(entry);
        currentTotalSize = _metadataStore.getCurrentCacheSize(); // Recalculate after deletion
      }
      print('Cache size enforced. Final size: ${currentTotalSize / (1024 * 1024)} MB.');
    }
  }

  /// Helper to delete a cached item (files + metadata).
  Future<void> _deleteCachedItem(CacheEntry entry) async {
    final FileSystemEntity fileOrDir;
    if (entry.isHls) {
      fileOrDir = Directory(entry.localPath);
    } else {
      fileOrDir = File(entry.localPath);
    }

    if (await fileOrDir.exists()) {
      try {
        await fileOrDir.delete(recursive: true);
        print('Deleted files for ${entry.trackId} from disk.');
      } catch (e) {
        print('Error deleting files for ${entry.trackId}: $e');
      }
    }
    await entry.delete(); // Delete from Hive (using HiveObject's delete)
    print('Deleted metadata for ${entry.trackId} from Hive.');
  }

  /// Calculates total size of a directory (used for HLS tracks).
  Future<int> _calculateDirectorySize(Directory dir) async {
    int size = 0;
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          size += await entity.length();
        } catch (e) {
          print('Error getting file size for ${entity.path}: $e');
        }
      }
    }
    return size;
  }

  /// Disposes resources held by the cache manager.
  Future<void> dispose() async {
    await _localProxyServer.dispose();
    _isInitialized = false; // Reset init state
    print('AudioCacheManager disposed.');
  }
}



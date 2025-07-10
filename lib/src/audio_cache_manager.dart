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


  Future<String?> getCachedAudioPath(String trackId) async {
    CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry == null) {
      return null;
    }

    if (entry.isHls) {
      // For HLS, we need to return the path to the local master manifest file.
      // The hlsLocalPath in CacheEntry is the *directory* path.
      final String originalFileName = p.basename(Uri.parse(entry.originalUrl).path);
      final String localMasterManifestPath = p.join(entry.hlsLocalPath!, originalFileName);
      if (await File(localMasterManifestPath).exists()) {
        return localMasterManifestPath;
      } else {
        AppLogger.warning('HLS manifest file not found at expected path: $localMasterManifestPath for track $trackId.', name: 'AudioCacheManager');
        return null;
      }
    } else {
      // For MP3s, filePath is the direct file path.
      if (await File(entry.filePath).exists()) {
        return entry.filePath;
      } else {
        AppLogger.warning('Cached MP3 file not found at expected path: ${entry.filePath} for track $trackId.', name: 'AudioCacheManager');
        return null;
      }
    }
  }

  /// Caches an audio URL and returns the local playback URL.
  Future<String?> cacheAudio(
      String url,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async {
    AppLogger.info('Caching audio for track $trackId. URL: $url', name: 'AudioCacheManager');

    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager not initialized. Cannot cache audio.', name: 'AudioCacheManager');
      return null;
    }

    // Check if audio is already cached and valid
    String? cachedPath = await getCachedAudioPath(trackId);
    if (cachedPath != null) {
      AppLogger.info('Track $trackId already cached. Returning local path: $cachedPath', name: 'AudioCacheManager');
      return cachedPath;
    }

    final Uri uri = Uri.parse(url);
    final String tempFileName = '${const Uuid().v4()}.tmp';
    final String tempFilePath = p.join(_cacheDirPath, tempFileName);
    final String finalFileName = const Uuid().v4();

    try {
      if (uri.path.endsWith('.m3u8')) {
        AppLogger.info('Track $trackId is HLS. Attempting to cache HLS stream.', name: 'APP');

        // This is the correct directory path for the HLS cache for this track.
        final String hlsCacheDirPath = p.join(_cacheDirPath, trackId);
        AppLogger.info('HLS cache directory path determined as: "$hlsCacheDirPath"', name: 'APP');

        final String? localManifestFilePath = await _hlsCacheHandler.cacheHls(
          url,
          _cacheDirPath, // Base cache dir passed to handler, so it can create trackId specific folder
          trackId,
          onProgress: onProgress,
        );

        if (localManifestFilePath == null) {
          AppLogger.error('Failed to cache HLS stream: $url', name: 'APP');
          return null;
        }

        // --- Crucial part: Ensure hlsLocalPath in CacheEntry stores the DIRECTORY path ---
        final newEntry = CacheEntry(
          trackId: trackId,
          originalUrl: url,
          filePath: '', // Not applicable for HLS
          timestamp: DateTime.now(),
          fileSize: 0, // Initial size, will be updated by cleanup or after calculation
          isEncrypted: false,
          etag: '',
          lastModified: '',
          contentType: 'application/x-mpegURL',
          proxyUrl: '',
          isHls: true,
          hlsLocalPath: hlsCacheDirPath, // Store the DIRECTORY path here
          hlsManifestFilePath: localManifestFilePath
        );

        AppLogger.info('Creating new CacheEntry for HLS. hlsLocalPath: "${newEntry.hlsLocalPath}"', name: 'APP');
        await _metadataStore.save(newEntry);
        AppLogger.info('CacheEntry for HLS saved to metadata store.', name: 'APP');

        // Calculate and update file size after saving, for accurate total size tracking
        int hlsCachedSize = 0;
        try {
          final Directory hlsDir = Directory(hlsCacheDirPath);
          if (await hlsDir.exists()) {
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsCachedSize += await entity.length();
              }
            }
          }
          newEntry.copyWith(fileSize: hlsCachedSize); // Update the filesize in the entry
          await _metadataStore.save(newEntry); // Save updated entry to persist size
          AppLogger.info('Calculated HLS cache size for $trackId: $hlsCachedSize bytes. Saved to CacheEntry.', name: 'APP');
        } catch (e, st) {
          AppLogger.error('Error calculating HLS cache size for $trackId: $e', error: e, stackTrace: st, name: 'APP');
        }

        // Trigger cleanup after saving and calculating size (this is where the problem log originates)
        await _cleanupCache();

        AppLogger.info('Cached HLS $trackId. Local manifest: $localManifestFilePath', name: 'APP');
        return localManifestFilePath; // Return the manifest path for playback
      } else {
        // ... (Existing MP3 caching logic) ...
        final http.Response response = await http.get(uri);
        if (response.statusCode == 200) {
          final File tempFile = File(tempFilePath);
          await tempFile.writeAsBytes(response.bodyBytes);

          final File finalFile = File(p.join(_cacheDirPath, finalFileName));
          await tempFile.rename(finalFile.path);

          final newEntry = CacheEntry(
            trackId: trackId,
            originalUrl: url,
            filePath: finalFile.path,
            timestamp: DateTime.now(),
            fileSize: response.contentLength??0,
            isEncrypted: false,
            etag: response.headers['etag'] ?? '',
            lastModified: response.headers['last-modified'] ?? '',
            contentType: response.headers['content-type'] ?? 'application/octet-stream',
            proxyUrl: '',
            isHls: false,
            hlsLocalPath: null,
          );
          await _metadataStore.save(newEntry);
          await _cleanupCache();

          return finalFile.path;
        } else {
          AppLogger.error('Failed to download audio from $url: ${response.statusCode}', name: 'APP');
          return null;
        }
      }
    } catch (e, st) {
      AppLogger.error('Error caching audio $url: $e', error: e, stackTrace: st, name: 'APP');
      final File tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        await tempFile.delete();
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

    // if (entry.isHls) {
    //   if (entry.hlsLocalPath == null || !await Directory(entry.hlsLocalPath!).exists()) {
    //     AppLogger.warning('HLS local path for $trackId is invalid or missing. Clearing metadata.', name: 'APP');
    //     await _metadataStore.delete(trackId);
    //     return null;
    //   }
    //   AppLogger.info('Track $trackId is HLS. Returning local manifest: ${entry.hlsLocalPath}', name: 'APP');
    //   return entry.hlsLocalPath;
    // } else {
    //   if (!await File(entry.filePath).exists()) {
    //     AppLogger.warning('File for $trackId does not exist at ${entry.filePath}. Clearing metadata.', name: 'APP');
    //     await _metadataStore.delete(trackId);
    //     return null;
    //   }
    //   AppLogger.info('Track $trackId is MP3. Returning proxy URL: ${entry.proxyUrl}', name: 'APP');
    //   return entry.proxyUrl;
    // }

    if (entry.isHls) {
      if (entry.hlsManifestFilePath != null) {
        final File manifestFile = File(entry.hlsManifestFilePath!);
        if (await manifestFile.exists()) {
          AppLogger.info('Track $trackId is HLS. Returning local manifest: ${entry.hlsManifestFilePath}', name: 'APP');
          return 'file://${entry.hlsManifestFilePath}'; // <--- THIS IS THE FIX
        } else {
          AppLogger.warning('HLS manifest file missing for $trackId at ${entry.hlsManifestFilePath}. Invalidating cache entry.', name: 'APP');
          await _metadataStore.delete(trackId); // Invalidate corrupted entry
          // Optional: Delete the directory
          final Directory trackDir = Directory(entry.hlsLocalPath!);
          if (await trackDir.exists()) {
            await trackDir.delete(recursive: true);
          }
          return null;
        }
      }
    } else {
      if (entry.filePath.isEmpty) {
        final File cachedFile = File(entry.filePath);
        if (await cachedFile.exists() &&
            await cachedFile.length() == entry.fileSize) {
          AppLogger.info(
              'Found valid cached MP3 for $trackId at ${entry.filePath}',
              name: 'APP');
          return 'file://${entry.filePath}';
        } else {
          AppLogger.warning(
              'Cached MP3 file for $trackId is missing or corrupted. Deleting entry.',
              name: 'APP');
          await _metadataStore.delete(trackId);
          return null;
        }
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


  /// Cleans up expired or overflowing cache entries.
  Future<void> _cleanupCache() async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager not initialized when calling _cleanupCache.', name: 'AudioCacheManager');
      return;
    }
    AppLogger.info('Performing cache cleanup...', name: 'AudioCacheManager');
    final List<CacheEntry> allEntries = await _metadataStore.getAll();
    final List<String> entriesToDelete = [];
    int currentTotalSize = 0;

    // First pass: identify entries to delete based on disk presence, expiration, or overflow
    for (final entry in allEntries) {
      bool deleteEntry = false;
      if (entry.isHls) {
        // Here, entry.cacheFileEntity is already a Directory based on hlsLocalPath
        final Directory hlsDir = entry.cacheFileEntity as Directory;

        AppLogger.info('Cleanup check for HLS track ${entry.trackId}. Expected directory path: "${hlsDir.path}"', name: 'AudioCacheManager');

        if (!await hlsDir.exists()) { // Check if the DIRECTORY exists
          AppLogger.warning('HLS directory for ${entry.trackId} not found on disk at "${hlsDir.path}". Marking for deletion.', name: 'AudioCacheManager');
          deleteEntry = true;
        } else {
          // Recalculate HLS size for accurate cleanup decision
          int hlsCurrentSize = 0;
          try {
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsCurrentSize += await entity.length();
              }
            }
            currentTotalSize += hlsCurrentSize;
            // Update the entry's filesize if it's different (e.g., from initial 0)
            if (entry.fileSize != hlsCurrentSize) {
              entry.copyWith(fileSize:  hlsCurrentSize);
              await _metadataStore.save(entry); // Save updated size to metadata
            }
          } catch (e, st) {
            AppLogger.warning('Could not calculate size for HLS directory ${hlsDir.path}: $e', name: 'AudioCacheManager');
            deleteEntry = true; // Mark for deletion if we can't even list it
          }

          if (DateTime.now().difference(entry.timestamp) > _expirationDuration) {
            AppLogger.info('HLS cache for ${entry.trackId} expired. Marking for deletion.', name: 'AudioCacheManager');
            deleteEntry = true;
          }
        }
      } else { // MP3 or single file
        final File file = entry.cacheFileEntity as File; // This is correctly a File
        if (!await file.exists()) {
          AppLogger.warning('File for ${entry.trackId} not found on disk. Marking for deletion.', name: 'AudioCacheManager');
          deleteEntry = true;
        } else {
          currentTotalSize += entry.fileSize;
          if (DateTime.now().difference(entry.timestamp) > _expirationDuration) {
            AppLogger.info('Cache for ${entry.trackId} expired. Marking for deletion.', name: 'AudioCacheManager');
            deleteEntry = true;
          }
        }
      }
      if (deleteEntry) {
        entriesToDelete.add(entry.trackId);
      }
    }

    // Second pass: delete based on overflow, prioritizing oldest
    // (Only if not already marked for deletion)
    List<CacheEntry> activeEntries = allEntries.where((e) => !entriesToDelete.contains(e.trackId)).toList();
    activeEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp)); // Sort by oldest first

    for (final entry in activeEntries) {
      if (currentTotalSize > _maxCacheSizeBytes) {
        AppLogger.info('Cache overflow. Deleting oldest entry ${entry.trackId}.', name: 'AudioCacheManager');
        if (entry.isHls) {
          final Directory hlsDir = entry.cacheFileEntity as Directory;
          AppLogger.info('Deleting expired/overflow HLS directory: ${hlsDir.path}', name: 'AudioCacheManager'); // This log should now show a directory path
          await _hlsCacheHandler.deleteCachedHls(hlsDir.path); // Pass the directory path
          // Recalculate size after deletion to accurately reduce currentTotalSize
          int hlsDeletedSize = 0;
          try {
            if (await hlsDir.exists()) { // Check again in case delete failed
              await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
                if (entity is File) {
                  hlsDeletedSize += await entity.length();
                }
              }
            }
          } catch (e) { /* ignore */ } // Ignore errors during size recalculation on deleted dir
          currentTotalSize -= hlsDeletedSize; // Subtract actual size deleted
        } else {
          final File file = entry.cacheFileEntity as File;
          if (await file.exists()) {
            await file.delete();
            currentTotalSize -= entry.fileSize;
          }
        }
        entriesToDelete.add(entry.trackId);
      } else {
        break; // Stop if no longer over capacity
      }
    }


    // Final pass: delete metadata for all identified entries
    for (final trackId in entriesToDelete) {
      await _metadataStore.delete(trackId);
      AppLogger.info('Deleted cache entry metadata for $trackId.', name: 'AudioCacheManager');
    }

    AppLogger.info('Cache cleanup complete. Current size: ${(currentTotalSize / (1024 * 1024)).toStringAsFixed(2)} MB', name: 'AudioCacheManager');
    // _metadataStore.updateCurrentCacheSize(currentTotalSize); // Update the store's internal total size
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
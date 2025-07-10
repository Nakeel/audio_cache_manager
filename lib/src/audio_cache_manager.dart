import 'dart:io';

import 'package:audio_cache_manager/handlers/hls_cache_handler.dart';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/handlers/mp3_cache_handler.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;

  AudioCacheManager._internal();

  late String _cacheDirPath;
  late CacheMetadataStore _metadataStore;
  late LocalProxyServer _proxyServer;
  late Mp3CacheHandler _mp3CacheHandler;
  late HlsCacheHandler _hlsCacheHandler;

  bool _isInitialized = false;
  Duration _expirationDuration = const Duration(days: 30);
  int _maxCacheSizeBytes = 500 * 1024 * 1024; // Default 500 MB

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) {
      AppLogger.warning('AudioCacheManager already initialized.', name: 'AudioCacheManager');
      return;
    }

    AppLogger.info('Initializing AudioCacheManager...', name: 'AudioCacheManager');

    _cacheDirPath = await _getCacheDirPath();
    _metadataStore = CacheMetadataStore();
    await _metadataStore.init();

    _proxyServer = LocalProxyServer(cacheDirPath: _cacheDirPath, metadataStore: _metadataStore);
    await _proxyServer.start();

    _mp3CacheHandler = Mp3CacheHandler();
    await _mp3CacheHandler.init(_cacheDirPath);

    _hlsCacheHandler = HlsCacheHandler(proxyServer: _proxyServer);

    _isInitialized = true;
    AppLogger.info('AudioCacheManager initialized. Cache directory: $_cacheDirPath', name: 'AudioCacheManager');
  }

  /// Caches an audio file (MP3 or HLS).
  /// Returns the local path or proxy URL to the cached file for playback.
  Future<String?> cacheAudio({
    required String trackId,
    required String originalUrl,
    bool isHls = false,
    bool encrypt = false,
    Function(int received, int total)? onProgress,
  }) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }

    final CacheEntry? existingEntry = await _metadataStore.get(trackId);
    if (existingEntry != null && existingEntry.originalUrl == originalUrl) {
      if (existingEntry.cacheFileEntity.existsSync()) {
        AppLogger.info('Audio $trackId already cached and exists on disk. Returning existing path.', name: 'AudioCacheManager');
        return getPlaybackUrl(trackId);
      } else {
        AppLogger.warning('Metadata for $trackId found, but file does not exist. Re-downloading.', name: 'AudioCacheManager');
        await _metadataStore.delete(trackId);
      }
    }

    AppLogger.info('Caching audio for trackId: $trackId, isHls: $isHls, encrypt: $encrypt', name: 'AudioCacheManager');

    String? localPath;
    int? fileSize;
    String contentType;
    String proxyUrl = ''; // Initialize proxyUrl

    if (isHls) {
      final String? hlsLocalMasterManifestPath = await _hlsCacheHandler.cacheHls(
        originalUrl,
        _cacheDirPath,
        trackId,
        onProgress: onProgress,
        encrypt: encrypt,
      );

      if (hlsLocalMasterManifestPath == null) {
        AppLogger.error('Failed to cache HLS for track $trackId.', name: 'AudioCacheManager');
        return null;
      }

      int hlsTotalSize = 0;
      final Directory hlsTrackDir = Directory(p.join(_cacheDirPath, trackId));
      if (await hlsTrackDir.exists()) {
        await for (var entity in hlsTrackDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            hlsTotalSize += await entity.length();
          }
        }
      }

      proxyUrl = _proxyServer.getHlsManifestProxyUrl(trackId, p.basename(Uri.parse(originalUrl).path));
      contentType = 'application/x-mpegURL';

      final newEntry = CacheEntry(
        trackId: trackId,
        originalUrl: originalUrl,
        filePath: '', // HLS doesn't have a single file path in this context
        timestamp: DateTime.now(),
        fileSize: hlsTotalSize,
        isEncrypted: encrypt, // HLS segments are decrypted on cache, but manifest might be served by proxy
        etag: '',
        lastModified: '',
        contentType: contentType,
        proxyUrl: proxyUrl,
        isHls: true,
        hlsLocalPath: hlsTrackDir.path,
        hlsManifestFilePath: hlsLocalMasterManifestPath,
      );
      await _metadataStore.save(newEntry);
      return proxyUrl;

    } else { // MP3 caching logic
      final Map<String, dynamic>? mp3CacheResult = await _mp3CacheHandler.cacheAudio(
        originalUrl,
        trackId,
        onProgress: onProgress,
        encrypt: encrypt,
      );

      if (mp3CacheResult == null) {
        AppLogger.error('Failed to cache MP3 for track $trackId.', name: 'AudioCacheManager');
        return null;
      }

      localPath = mp3CacheResult['localPath'] as String;
      fileSize = mp3CacheResult['fileSize'] as int;
      contentType = 'audio/mpeg';

      // If MP3 is encrypted, its playback URL MUST be through the proxy server.
      if (encrypt) {
        proxyUrl = _proxyServer.getProxyUrl(trackId);
        AppLogger.info('Generated proxy URL for encrypted MP3 $trackId: $proxyUrl', name: 'AudioCacheManager');
      }

      final newEntry = CacheEntry(
        trackId: trackId,
        originalUrl: originalUrl,
        filePath: localPath,
        timestamp: DateTime.now(),
        fileSize: fileSize,
        isEncrypted: encrypt,
        etag: '',
        lastModified: '',
        contentType: contentType,
        proxyUrl: proxyUrl, // This will be set for encrypted MP3s to force proxy playback
        isHls: false,
        hlsLocalPath: null,
        hlsManifestFilePath: null,
      );
      await _metadataStore.save(newEntry);

      // Return the proxy URL if encrypted, else the local path
      return encrypt ? proxyUrl : localPath;
    }
  }

  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }
      final CacheEntry? entry = await _metadataStore.get(trackId);
      if (entry == null) {
        AppLogger.warning('Cache entry not found for trackId: $trackId', name: 'AudioCacheManager');
        return null;
      }

      AppLogger.info('DEBUG: Retrieved CacheEntry for $trackId. isHls: ${entry.isHls}, isEncrypted: ${entry.isEncrypted}', name: 'AudioCacheManager');

      // CRITICAL CHANGE FOR ENCRYPTED HLS:
      // If it's HLS AND encrypted, it must go through the proxy for decryption of segments.
      // Otherwise, for unencrypted HLS, play directly from file://.
      if (entry.isHls && entry.isEncrypted) { // <-- NEW CONDITION
        AppLogger.info('Returning PROXY URL for ENCRYPTED HLS: $trackId', name: 'AudioCacheManager');
        final proxyUrl = _proxyServer.getProxyUrl(trackId); // Generate proxy URL for the main track ID
        if (proxyUrl.isEmpty) {
          AppLogger.error('Proxy server not active for encrypted HLS playback.', name: 'AudioCacheManager');
          return null;
        }
        return proxyUrl; // Serve the main manifest through the proxy
      } else if (entry.isHls) { // Unencrypted HLS: play directly from file
        final String localManifestPath = entry.hlsManifestFilePath!;
        AppLogger.info('Returning HLS local manifest path (unencrypted): $localManifestPath', name: 'AudioCacheManager');
        return 'file://$localManifestPath';
      }
      else {
        // Existing MP3 logic (also uses proxy for encrypted MP3s)
        final File cachedFile = File(entry.filePath);
        if (await cachedFile.exists()) {
          if (entry.isEncrypted) {
            final proxyUrl = _proxyServer.getProxyUrl(trackId);
            if (proxyUrl.isEmpty) {
              AppLogger.error('Proxy server not active when trying to get proxy URL for encrypted MP3.', name: 'AudioCacheManager');
              return null;
            }
            AppLogger.info('Returning MP3 proxy URL for encrypted file: $proxyUrl', name: 'AudioCacheManager');
            return proxyUrl;
          } else {
            AppLogger.info('Returning direct MP3 file path for unencrypted file: ${cachedFile.path}', name: 'AudioCacheManager');
            return 'file://${cachedFile.path}';
          }
        } else {
          AppLogger.warning('Cached file not found for trackId: $trackId at ${entry.filePath}', name: 'AudioCacheManager');
          return null;
        }
      }
    }


  /// Checks if an audio track is cached.
  Future<bool> isAudioCached(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return false;
    }
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry == null) {
      return false;
    }
    return entry.cacheFileEntity.existsSync();
  }

  /// Deletes a cached audio file.
  Future<void> deleteCachedAudio(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return;
    }
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry != null) {
      AppLogger.info('Attempting to delete cache for $trackId', name: 'AudioCacheManager');
      try {
        if (entry.isHls) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          if (await hlsDir.exists()) {
            await hlsDir.delete(recursive: true);
            AppLogger.info('Deleted HLS cache directory: ${hlsDir.path}', name: 'AudioCacheManager');
          }
        } else {
          final File file = File(entry.filePath);
          if (await file.exists()) {
            await file.delete();
            AppLogger.info('Deleted MP3 cache file: ${file.path}', name: 'AudioCacheManager');
          }
        }
        await _metadataStore.delete(trackId);
        AppLogger.info('Successfully deleted cache entry for $trackId.', name: 'AudioCacheManager');
      } catch (e, st) {
        AppLogger.error('Error deleting cache for $trackId: $e', error: e, stackTrace: st, name: 'AudioCacheManager');
      }
    } else {
      AppLogger.info('No cache entry found for $trackId to delete.', name: 'AudioCacheManager');
    }
  }

  /// Clears all cached audio files and their metadata.
  Future<void> clearAllCache() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return;
    }
    AppLogger.info('Clearing all cache...', name: 'AudioCacheManager');
    try {
      final List<CacheEntry> allEntries = await _metadataStore.getAll();
      for (final entry in allEntries) {
        if (entry.isHls) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          if (await hlsDir.exists()) {
            await hlsDir.delete(recursive: true);
          }
        } else {
          final File file = File(entry.filePath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
      await _metadataStore.clear(); // Clear all metadata
      // Also delete the base cache directory content to be absolutely sure
      final Directory cacheDir = Directory(_cacheDirPath);
      if (await cacheDir.exists()) {
        // Only delete contents, not the directory itself, as it might be recreated on next init
        await for (var entity in cacheDir.list(recursive: false, followLinks: false)) {
          if (entity is File) {
            await entity.delete();
          } else if (entity is Directory) {
            await entity.delete(recursive: true);
          }
        }
      }
      AppLogger.info('All cache cleared successfully.', name: 'AudioCacheManager');
    } catch (e, st) {
      AppLogger.error('Error clearing all cache: $e', error: e, stackTrace: st, name: 'AudioCacheManager');
    }
  }


  /// Returns the number of currently cached audio items.
  Future<int> getCachedItemCount() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return 0;
    }
    return (await _metadataStore.getAll()).length;
  }

  /// Returns the total size of currently cached audio items in bytes.
  Future<int> getCurrentCacheSize() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return 0;
    }
    return _metadataStore.getCurrentCacheSize(); // Delegate to CacheMetadataStore
  }

  /// Cleans up the cache based on size and expiration duration.
  Future<void> _cleanupCache() async {
    if (!_isInitialized) return;
    AppLogger.info('Running cache cleanup...', name: 'AudioCacheManager');

    final List<CacheEntry> allEntries = await _metadataStore.getAll();
    allEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    int currentTotalSize = _metadataStore.getCurrentCacheSize();
    final List<String> entriesToDelete = [];

    // 1. Delete expired entries
    final DateTime now = DateTime.now();
    for (final entry in allEntries) {
      if (now.difference(entry.timestamp) > _expirationDuration) {
        AppLogger.info('Deleting expired entry: ${entry.trackId}', name: 'AudioCacheManager');
        if (entry.isHls && entry.hlsLocalPath != null) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          if (await hlsDir.exists()) {
            int hlsDeletedSize = 0;
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsDeletedSize += await entity.length();
              }
            }
            await hlsDir.delete(recursive: true);
            currentTotalSize -= hlsDeletedSize;
          } else {
            currentTotalSize -= entry.fileSize;
          }
        } else {
          final File file = File(entry.filePath);
          if (await file.exists()) {
            await file.delete();
            currentTotalSize -= entry.fileSize;
          } else {
            currentTotalSize -= entry.fileSize;
          }
        }
        entriesToDelete.add(entry.trackId);
      }
    }

    final List<CacheEntry> remainingEntries = (await _metadataStore.getAll())..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    for (final entry in remainingEntries) {
      if (currentTotalSize > _maxCacheSizeBytes) {
        AppLogger.info('Cache over capacity. Deleting oldest entry: ${entry.trackId}', name: 'AudioCacheManager');
        if (entry.isHls && entry.hlsLocalPath != null) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          int hlsDeletedSize = 0;
          if (await hlsDir.exists()) {
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsDeletedSize += await entity.length();
              }
            }
            await hlsDir.delete(recursive: true);
          }
          currentTotalSize -= hlsDeletedSize;
        } else {
          final File file = File(entry.filePath);
          if (await file.exists()) {
            await file.delete();
            currentTotalSize -= entry.fileSize;
          }
        }
        entriesToDelete.add(entry.trackId);
      } else {
        break;
      }
    }

    for (final trackId in entriesToDelete) {
      await _metadataStore.delete(trackId);
      AppLogger.info('Deleted cache entry metadata for $trackId.', name: 'AudioCacheManager');
    }

    AppLogger.info('Cache cleanup complete. Current size: ${(currentTotalSize / (1024 * 1024)).toStringAsFixed(2)} MB', name: 'AudioCacheManager');
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

  void setMaxCacheSize(int bytes) {
    if (bytes < 0) {
      AppLogger.warning('Max cache size cannot be negative. Setting to 0.', name: 'AudioCacheManager');
      _maxCacheSizeBytes = 0;
    } else {
      _maxCacheSizeBytes = bytes;
      AppLogger.info('Max cache size set to ${(_maxCacheSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB', name: 'AudioCacheManager');
    }
  }

  int getMaxCacheSize() => _maxCacheSizeBytes;

  void setExpirationDuration(Duration duration) {
    if (duration.isNegative) {
      AppLogger.warning('Expiration duration cannot be negative. Setting to 0.', name: 'AudioCacheManager');
      _expirationDuration = Duration.zero;
    } else {
      _expirationDuration = duration;
      AppLogger.info('Expiration duration set to ${_expirationDuration.inDays} days', name: 'AudioCacheManager');
    }
  }

  Duration getExpirationDuration() => _expirationDuration;
}
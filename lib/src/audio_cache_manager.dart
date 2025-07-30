import 'dart:io';

import 'package:audio_cache_manager/handlers/hls_cache_handler.dart';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/handlers/mp3_cache_handler.dart';
import 'package:audio_cache_manager/handlers/network_checker.dart';
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
  late InternetChecker _internetChecker;

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

    _internetChecker = InternetChecker();

    _hlsCacheHandler = HlsCacheHandler(
      proxyServer: _proxyServer,
      metadataStore: _metadataStore,
      internetChecker: _internetChecker,
    );

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
      bool isActuallyCached = false;
      if (existingEntry.isHls) {
        isActuallyCached = existingEntry.hlsSegments?.any((s) => s.isComplete) ?? false;
      } else {
        isActuallyCached = existingEntry.cacheFileEntity.existsSync();
      }

      if (isActuallyCached) {
        AppLogger.info('Audio $trackId already cached (or partially cached HLS) and exists on disk. Resuming/Returning existing path.', name: 'AudioCacheManager');
        if (!isHls) {
          return getPlaybackUrl(trackId);
        }
      } else {
        AppLogger.warning('Metadata for $trackId found, but file/segments do not exist. Re-downloading.', name: 'AudioCacheManager');
        await _metadataStore.delete(trackId);
      }
    }

    AppLogger.info('Caching audio for trackId: $trackId, isHls: $isHls, encrypt: $encrypt', name: 'AudioCacheManager');

    String? playbackUrl;
    int? totalCachedSize;
    String? finalDataHash; // To store the hash for MP3s

    if (isHls) {
      final String? hlsLocalDirPath = await _hlsCacheHandler.cacheHls(
        originalUrl,
        _cacheDirPath,
        trackId,
        onProgress: onProgress,
        encrypt: encrypt,
      );

      if (hlsLocalDirPath == null) {
        AppLogger.error('Failed to cache HLS for track $trackId.', name: 'AudioCacheManager');
        return null;
      }

      final updatedEntry = await _metadataStore.get(trackId);
      totalCachedSize = updatedEntry?.fileSize ?? 0;

      playbackUrl = _proxyServer.getProxyUrl(trackId);
      if (playbackUrl.isEmpty) {
        AppLogger.error('Proxy URL for HLS master manifest is empty. Cannot play.', name: 'AudioCacheManager');
        return null;
      }
      AppLogger.info('Generated proxy URL for HLS master manifest $trackId: $playbackUrl', name: 'AudioCacheManager');

      if (updatedEntry != null) {
        await _metadataStore.save(updatedEntry.copyWith(proxyUrl: playbackUrl));
      } else {
        final newEntry = CacheEntry(
          trackId: trackId,
          originalUrl: originalUrl,
          filePath: '',
          timestamp: DateTime.now(),
          fileSize: totalCachedSize,
          isEncrypted: encrypt,
          etag: '',
          lastModified: '',
          contentType: 'application/x-mpegURL',
          proxyUrl: playbackUrl,
          isHls: true,
          hlsLocalPath: hlsLocalDirPath,
          hlsSegments: updatedEntry?.hlsSegments,
          dataHash: null, // HLS master entry doesn't have a single dataHash
        );
        await _metadataStore.save(newEntry);
      }

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

      final String localPath = mp3CacheResult['localPath'] as String;
      totalCachedSize = mp3CacheResult['fileSize'] as int;
      finalDataHash = mp3CacheResult['dataHash'] as String?; // NEW: Get the dataHash

      if (encrypt) {
        playbackUrl = _proxyServer.getProxyUrl(trackId);
        if (playbackUrl.isEmpty) {
          AppLogger.error('Proxy URL for encrypted MP3 is empty. Cannot play.', name: 'AudioCacheManager');
          return null;
        }
        AppLogger.info('Generated proxy URL for encrypted MP3 $trackId: $playbackUrl', name: 'AudioCacheManager');
      } else {
        playbackUrl = 'file://$localPath';
        AppLogger.info('Generated direct file URL for unencrypted MP3 $trackId: $playbackUrl', name: 'AudioCacheManager');
      }

      final newEntry = CacheEntry(
        trackId: trackId,
        originalUrl: originalUrl,
        filePath: localPath,
        timestamp: DateTime.now(),
        fileSize: totalCachedSize,
        isEncrypted: encrypt,
        etag: '',
        lastModified: '',
        contentType: 'audio/mpeg',
        proxyUrl: encrypt ? playbackUrl : '',
        isHls: false,
        hlsLocalPath: null,
        hlsSegments: null,
        dataHash: finalDataHash, // NEW: Store the dataHash in CacheEntry
      );
      await _metadataStore.save(newEntry);
    }
    return playbackUrl;
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

    try {
      if (entry.isHls) {
        final proxyUrl = _proxyServer.getProxyUrl(trackId);
        if (proxyUrl.isEmpty) {
          AppLogger.error('Proxy URL for HLS master manifest is empty. Cannot play.', name: 'AudioCacheManager');
          return null;
        }
        AppLogger.info('Returning HLS proxy URL: $proxyUrl', name: 'AudioCacheManager');
        return proxyUrl;
      }
      else {
        final File cachedFile = File(entry.filePath);
        if (await cachedFile.exists()) {
          // For MP3s, the integrity check for unencrypted files can happen here,
          // but for encrypted files, it MUST happen in the proxy after decryption.
          // To simplify, we'll rely on the proxy for all integrity checks on playback.
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
    } catch (e) {
      AppLogger.warning('Could not get playback url for: $trackId at ${entry.filePath}. Error: $e', name: 'AudioCacheManager');
    }
    return null;
  }


  /// Checks if an audio track is cached.
  /// For HLS, considers it cached if at least one segment is complete.
  @override
  Future<bool> isAudioCached(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return false;
    }
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry == null) {
      return false;
    }
    if (entry.isHls) {
      final Directory hlsDir = Directory(entry.hlsLocalPath!);
      // For HLS, consider it cached if the directory exists and at least one segment is complete AND has a hash
      return await hlsDir.exists() && (entry.hlsSegments?.any((s) => s.isComplete && s.dataHash != null) ?? false);
    } else {
      // For MP3, check if the file exists AND has a hash
      return entry.cacheFileEntity.existsSync() && entry.dataHash != null;
    }
  }

  /// Deletes a cached audio file.
  @override
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
  @override
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
      await _metadataStore.clear();
      final Directory cacheDir = Directory(_cacheDirPath);
      if (await cacheDir.exists()) {
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
  @override
  Future<int> getCachedItemCount() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return 0;
    }
    return (await _metadataStore.getAll()).length;
  }

  /// Returns the total size of currently cached audio items in bytes.
  @override
  Future<int> getCurrentCacheSize() async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return 0;
    }
    return _metadataStore.getCurrentCacheSize();
  }

  /// Cleans up the cache based on size and expiration duration.
  Future<void> _cleanupCache() async {
    if (!_isInitialized) return;
    AppLogger.info('Running cache cleanup...', name: 'AudioCacheManager');

    final List<CacheEntry> allEntries = await _metadataStore.getAll();
    allEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    int currentTotalSize = _metadataStore.getCurrentCacheSize();
    final List<String> entriesToDelete = [];

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
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(appDocDir.path, 'audio_cache'));

    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  void dispose() {
    if (_isInitialized) {
      _proxyServer.stop();
      _metadataStore.close();
      _internetChecker.dispose();
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

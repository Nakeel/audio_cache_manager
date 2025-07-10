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
  late Mp3CacheHandler _mp3CacheHandler;
  late HlsCacheHandler _hlsCacheHandler; // Now requires proxyServer

  bool _isInitialized = false;
  Duration _expirationDuration = const Duration(days: 30);
  int _maxCacheSizeBytes = 500 * 1024 * 1024; // Default 500 MB

  // Track initialisation state, for external access if needed
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

    // Initialize LocalProxyServer AFTER metadataStore is ready
    _proxyServer = LocalProxyServer(cacheDirPath: _cacheDirPath, metadataStore: _metadataStore);
    await _proxyServer.start(); // Start the proxy server

    _mp3CacheHandler = Mp3CacheHandler();
    await _mp3CacheHandler.init(_cacheDirPath); // Pass the base cache path

    // Initialize HlsCacheHandler with the proxyServer instance
    _hlsCacheHandler = HlsCacheHandler(proxyServer: _proxyServer);

    _isInitialized = true;
    AppLogger.info('AudioCacheManager initialized. Cache directory: $_cacheDirPath', name: 'AudioCacheManager');

    // Run initial cleanup after initialization
    // _cleanupCache(); // Moved to be called explicitly or periodically later
  }

  /// Caches an audio file (MP3 or HLS).
  /// Returns the local path or proxy URL to the cached file for playback.
  Future<String?> cacheAudio({
    required String trackId,
    required String originalUrl,
    bool isHls = false,
    bool encrypt = false, // Add encrypt parameter here
    Function(int received, int total)? onProgress,
  }) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }

    // Check if already cached and valid
    final CacheEntry? existingEntry = await _metadataStore.get(trackId);
    if (existingEntry != null && existingEntry.originalUrl == originalUrl) {
      // Basic validation: Check if file exists on disk
      if (existingEntry.cacheFileEntity.existsSync()) {
        AppLogger.info('Audio $trackId already cached and exists on disk. Returning existing path.', name: 'AudioCacheManager');
        return getPlaybackUrl(trackId); // Return existing proxy/local URL
      } else {
        AppLogger.warning('Metadata for $trackId found, but file does not exist. Re-downloading.', name: 'AudioCacheManager');
        await _metadataStore.delete(trackId); // Clean up stale metadata
      }
    }

    AppLogger.info('Caching audio for trackId: $trackId, isHls: $isHls, encrypt: $encrypt', name: 'AudioCacheManager');

    String? localPath;
    int? fileSize;
    String contentType;
    String proxyUrl = ''; // Default empty, will be set for HLS and if MP3 proxying desired

    if (isHls) {
      // HLS Caching
      final String? hlsLocalMasterManifestPath = await _hlsCacheHandler.cacheHls(
        originalUrl,
        _cacheDirPath,
        trackId,
        onProgress: onProgress,
        encrypt: encrypt, // Pass encrypt flag to HlsCacheHandler
      );

      if (hlsLocalMasterManifestPath == null) {
        AppLogger.error('Failed to cache HLS for track $trackId.', name: 'AudioCacheManager');
        return null;
      }

      // Calculate total size of HLS cache for metadata
      int hlsTotalSize = 0;
      final Directory hlsTrackDir = Directory(p.join(_cacheDirPath, trackId));
      if (await hlsTrackDir.exists()) {
        await for (var entity in hlsTrackDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            hlsTotalSize += await entity.length();
          }
        }
      }

      // The playback URL for HLS will be the proxy URL to its master manifest
      proxyUrl = _proxyServer.getHlsManifestProxyUrl(trackId, p.basename(Uri.parse(originalUrl).path));
      contentType = 'application/x-mpegURL'; // Standard HLS content type

      final newEntry = CacheEntry(
        trackId: trackId,
        originalUrl: originalUrl,
        filePath: '', // Not applicable for HLS directly
        timestamp: DateTime.now(),
        fileSize: hlsTotalSize, // Store total size of HLS directory
        isEncrypted: encrypt,
        etag: '', // Not typically applicable for HLS full stream
        lastModified: '',
        contentType: contentType,
        proxyUrl: proxyUrl, // Store proxy URL for HLS playback
        isHls: true,
        hlsLocalPath: hlsTrackDir.path,
        hlsManifestFilePath: hlsLocalMasterManifestPath, // Path to the local rewritten master manifest
      );
      await _metadataStore.save(newEntry);
      return proxyUrl;

    } else {
      // MP3 Caching
      final Map<String, dynamic>? mp3CacheResult = await _mp3CacheHandler.cacheAudio(
        originalUrl,
        trackId,
        onProgress: onProgress,
        encrypt: encrypt, // Pass encrypt flag to Mp3CacheHandler
      );

      if (mp3CacheResult == null) {
        AppLogger.error('Failed to cache MP3 for track $trackId.', name: 'AudioCacheManager');
        return null;
      }

      localPath = mp3CacheResult['localPath'] as String;
      fileSize = mp3CacheResult['fileSize'] as int;
      contentType = 'audio/mpeg'; // Standard MP3 content type

      // For MP3s, we can either return the localPath or the proxyUrl
      // Based on our previous discussion and your current working setup,
      // we'll primarily use the localPath for MP3s for direct playback.
      // If you later decide to force MP3s through proxy (Phase 2), change this.
      // proxyUrl = _proxyServer.getMp3ProxyUrl(trackId); // Uncomment this line to use proxy for MP3s

      final newEntry = CacheEntry(
        trackId: trackId,
        originalUrl: originalUrl,
        filePath: localPath,
        timestamp: DateTime.now(),
        fileSize: fileSize,
        isEncrypted: encrypt,
        etag: '', // Can be extended to store ETag/Last-Modified for revalidation
        lastModified: '',
        contentType: contentType,
        proxyUrl: proxyUrl, // This will be empty string if not using proxy for MP3s
        isHls: false,
        hlsLocalPath: null,
        hlsManifestFilePath: null,
      );
      await _metadataStore.save(newEntry);

      // Return the direct local path for MP3s, unless you uncommented the proxyUrl line above
      return localPath;
    }
  }

  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      AppLogger.error('AudioCacheManager not initialized. Call init() first.', name: 'AudioCacheManager');
      return null;
    }
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry == null) {
      AppLogger.warning('No cache entry found for $trackId.', name: 'AudioCacheManager');
      return null;
    }

    // Validate if the file/directory still exists on disk
    if (!entry.cacheFileEntity.existsSync()) {
      AppLogger.warning('Cached file/directory for $trackId does not exist on disk. Deleting metadata.', name: 'AudioCacheManager');
      _metadataStore.delete(trackId); // Clean up stale metadata
      return null;
    }

    // HLS content always uses the proxy URL for playback
    if (entry.isHls) {
      // The proxyUrl in CacheEntry for HLS should now be the proxy URL to its master manifest
      return entry.proxyUrl;
    } else {
      // MP3s either use direct filePath or proxyUrl if configured
      // Based on current setup, MP3s use filePath for direct playback
      if (entry.proxyUrl.isNotEmpty) {
        return entry.proxyUrl; // If you decide to set proxyUrl for MP3s
      }
      return entry.filePath; // This is what is currently used for MP3s
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
    // Also verify that the actual file/directory exists on disk
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
          // For HLS, delete the entire directory
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          if (await hlsDir.exists()) {
            await hlsDir.delete(recursive: true);
            AppLogger.info('Deleted HLS cache directory: ${hlsDir.path}', name: 'AudioCacheManager');
          }
        } else {
          // For MP3s, delete the single file
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

  /// Cleans up the cache based on size and expiration duration.
  Future<void> _cleanupCache() async {
    if (!_isInitialized) return;
    AppLogger.info('Running cache cleanup...', name: 'AudioCacheManager');

    final List<CacheEntry> allEntries = await _metadataStore.getAll();
    allEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp)); // Sort by oldest first

    int currentTotalSize = _metadataStore.getCurrentCacheSize(); // Get current size from store
    final List<String> entriesToDelete = [];

    // 1. Delete expired entries
    final DateTime now = DateTime.now();
    for (final entry in allEntries) {
      if (now.difference(entry.timestamp) > _expirationDuration) {
        AppLogger.info('Deleting expired entry: ${entry.trackId}', name: 'AudioCacheManager');
        if (entry.isHls && entry.hlsLocalPath != null) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          if (await hlsDir.exists()) {
            // Need to get actual size of HLS dir before deleting for accurate accounting
            int hlsDeletedSize = 0;
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsDeletedSize += await entity.length();
              }
            }
            await hlsDir.delete(recursive: true);
            currentTotalSize -= hlsDeletedSize;
          } else {
            // If directory doesn't exist, just remove its metadata
            currentTotalSize -= entry.fileSize; // Assume stored size for accounting
          }
        } else {
          final File file = File(entry.filePath);
          if (await file.exists()) {
            await file.delete();
            currentTotalSize -= entry.fileSize;
          } else {
            // If file doesn't exist, just remove its metadata
            currentTotalSize -= entry.fileSize; // Assume stored size for accounting
          }
        }
        entriesToDelete.add(entry.trackId);
      }
    }

    // 2. Delete oldest entries if still over capacity
    // Re-fetch all entries after expiring some, to get an updated sorted list
    final List<CacheEntry> remainingEntries = (await _metadataStore.getAll())..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    for (final entry in remainingEntries) {
      if (currentTotalSize > _maxCacheSizeBytes) {
        AppLogger.info('Cache over capacity. Deleting oldest entry: ${entry.trackId}', name: 'AudioCacheManager');
        if (entry.isHls && entry.hlsLocalPath != null) {
          final Directory hlsDir = Directory(entry.hlsLocalPath!);
          int hlsDeletedSize = 0; // Calculate actual size for accounting
          if (await hlsDir.exists()) {
            await for (var entity in hlsDir.list(recursive: true, followLinks: false)) {
              if (entity is File) {
                hlsDeletedSize += await entity.length();
              }
            }
            await hlsDir.delete(recursive: true);
          }
          currentTotalSize -= hlsDeletedSize; // Subtract actual size deleted
        } else {
          final File file = File(entry.filePath);
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

  // --- Public Getters/Setters for Configuration ---
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
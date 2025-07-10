import 'dart:io';
import 'dart:typed_data';

import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/handlers/mp3_cache_handler.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';


class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();

  factory AudioCacheManager() => _instance;

  AudioCacheManager._internal();

  late CacheMetadataStore _metadataStore;
  late Mp3CacheHandler _mp3CacheHandler; // For MP3 download/cache
  late LocalProxyServer _proxyServer; // For serving decrypted/cached files

  bool _isInitialized = false;
  Duration expirationDuration = const Duration(days: 30);
  int maxCacheSizeBytes = 100 * 1024 * 1024; // Default 100 MB
  bool _enableEncryption = false; // Internal flag for encryption status

  String get cacheDirPath =>
      _mp3CacheHandler.cacheDirPath; // Expose cache directory path


  Future<void> init() async {
    if (_isInitialized) return;

    _metadataStore = CacheMetadataStore();
    await _metadataStore.init();

    _mp3CacheHandler = Mp3CacheHandler();
    await _mp3CacheHandler
        .init(); // Ensure MP3 handler is initialized to get cache path

    _proxyServer = LocalProxyServer(
      cacheDirPath: _mp3CacheHandler.cacheDirPath, // Pass cache path to proxy
      metadataStore: _metadataStore, // Pass metadata store to proxy
      // Add encryption helper here later when implemented
    );
    await _proxyServer.start(); // Start the local proxy server

    await _cleanupCache(); // Initial cleanup
    _isInitialized = true;
    AppLogger.info(
        'AudioCacheManager initialized. Cache path: ${cacheDirPath}');
  }

  void configure({
    Duration? expirationDuration,
    int? maxCacheSizeBytes,
    bool? enableEncryption,
  }) {
    if (_isInitialized) {
      AppLogger.warning(
          'AudioCacheManager is already initialized. Configuration changes might not take full effect.');
    }
    this.expirationDuration = expirationDuration ?? this.expirationDuration;
    this.maxCacheSizeBytes = maxCacheSizeBytes ?? this.maxCacheSizeBytes;
    this._enableEncryption = enableEncryption ?? this._enableEncryption;
    AppLogger.info(
        'AudioCacheManager configured: Expiration=${this.expirationDuration
            .inDays} days, MaxSize=${(this.maxCacheSizeBytes / (1024 * 1024))
            .toStringAsFixed(2)} MB, Encryption=${this._enableEncryption}');
  }

  /// Disposes resources held by the cache manager.
  void dispose() {
    if (_isInitialized) {
      // _metadataStore.dispose();
      _proxyServer.stop(); // Stop the proxy server
      _isInitialized = false;
      AppLogger.info('AudioCacheManager disposed.');
    }
  }

  // Helper to determine if a URL is likely an HLS stream
  bool _isHlsUrl(String url) {
    // Basic check for .m3u8 extension. Can be expanded for other HLS indicators.
    return url.toLowerCase().contains('.m3u8');
  }


  /// Caches an audio track and returns the local file URI for playback.
  /// Returns null if caching fails or is not applicable.
  // @override // Add this if it implements an interface
  Future<String?> cacheAudio(String originalUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async
  {
    if (!_isInitialized) {
      AppLogger.warning(
          'AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final bool isHls = _isHlsUrl(originalUrl); // Detect HLS
    final bool shouldEncrypt = _enableEncryption &&
        !isHls; // Only encrypt if not HLS

    try {
      // Check if already cached and still valid
      final existingEntry = await _metadataStore.get(trackId);
      if (existingEntry != null &&
          DateTime.now().difference(existingEntry.cachedAt) <
              expirationDuration) {
        // If it's an HLS entry, we just return the original URL (no local caching for HLS in Phase 2)
        if (existingEntry.isHls) {
          AppLogger.info(
              'HLS track $trackId already present in metadata. Returning original URL: ${existingEntry
                  .url}');
          existingEntry.updateAccessedTime();
          await existingEntry.save();
          return existingEntry.url;
        }
        // For non-HLS (MP3) files, proceed with file existence and size checks
        else if (await File(existingEntry.localPath).exists()) {
          final int actualFileSize = await File(existingEntry.localPath)
              .length();
          if (actualFileSize == existingEntry.fileSize &&
              existingEntry.isEncrypted ==
                  shouldEncrypt) { // Check encryption status matches configuration
            AppLogger.info(
                'Audio $trackId already cached and valid. Path: ${existingEntry
                    .localPath}');
            existingEntry.updateAccessedTime();
            await existingEntry.save();
            // If encrypted, return proxy URL; otherwise, return file:/// URI
            return existingEntry.isEncrypted
                ? 'http://localhost:${_proxyServer
                .port}/audio/$trackId' // Use proxy for encrypted
                : Uri
                .file(existingEntry.localPath)
                .toString(); // Direct file:/// for unencrypted
          } else {
            AppLogger.warning(
                'Cache entry for $trackId found but file size/encryption mismatch. Re-downloading.');
            await _cleanupPartialDownload(trackId, existingEntry.isHls);
          }
        } else {
          AppLogger.warning(
              'Cached file for $trackId missing on disk. Re-downloading.');
          await _cleanupPartialDownload(
              trackId, existingEntry.isHls); // Clean up inconsistent entry
        }
      }

      // If not cached, or cache invalid, proceed with download/metadata update
      if (isHls) {
        // For HLS, just create metadata entry, no download
        final newEntry = CacheEntry(
          trackId: trackId,
          url: originalUrl,
          localPath: originalUrl,
          // Store original URL as localPath for HLS
          cachedAt: DateTime.now(),
          lastAccessedAt: DateTime.now(),
          fileSize: 0,
          // HLS doesn't have a single file size
          isEncrypted: false,
          // HLS not encrypted by our system (streamed directly)
          isHls: true,
        );
        await _metadataStore.save(newEntry);
        AppLogger.info(
            'HLS track $trackId added to cache metadata. Will be streamed directly: $originalUrl');
        return originalUrl; // Return original URL for HLS playback
      } else {
        // For MP3s, proceed with download and potentially encryption
        final result = await _mp3CacheHandler.cacheAudio(
            originalUrl, cacheDirPath, onProgress: onProgress,
            encrypt: shouldEncrypt);

        if (result != null) {
          final String finalLocalPath = result['localPath'];
          final int fileSize = result['fileSize'];

          final newEntry = CacheEntry(
            trackId: trackId,
            url: originalUrl,
            localPath: finalLocalPath,
            cachedAt: DateTime.now(),
            lastAccessedAt: DateTime.now(),
            fileSize: fileSize,
            isEncrypted: shouldEncrypt,
            isHls: false, // Explicitly false for MP3s
          );
          await _metadataStore.save(newEntry);
          AppLogger.info('Cached audio $trackId: ${newEntry.url} to ${newEntry
              .localPath}, Size: $fileSize bytes. Encrypted: $shouldEncrypt');
          // If encrypted, return proxy URL; otherwise, return file:/// URI
          return shouldEncrypt
              ? 'http://localhost:${_proxyServer
              .port}/audio/$trackId' // Use proxy for encrypted
              : Uri
              .file(finalLocalPath)
              .toString(); // Direct file:/// for unencrypted
        }
        return null;
      }
    } catch (e, st) {
      AppLogger.error(
          'Error in cacheAudio for $trackId: $e', error: e, stackTrace: st);
      await _cleanupPartialDownload(trackId, isHls);
      return null;
    } finally {
      await _cleanupCache();
    }
  }

  /// Gets the playback URL for a cached audio track (direct file path or proxy URL).
  /// Returns null if the track is not cached or invalid.
  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning(
          'AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final CacheEntry? entry = await _metadataStore.get(trackId);

    if (entry == null) {
      AppLogger.info('Track $trackId not found in cache metadata.');
      return null;
    }

    // Handle HLS streams: always return original URL for direct streaming
    if (entry.isHls) {
      AppLogger.info(
          'Track $trackId is HLS. Returning original URL for direct streaming: ${entry
              .url}');
      entry.updateAccessedTime();
      await entry.save();
      return entry.url;
    }

    // For non-HLS (MP3) files, proceed with local file checks
    final File file = File(entry.localPath);
    if (!await file.exists()) {
      AppLogger.info(
          'Files for $trackId missing on disk. Cleaning up metadata.');
      await _metadataStore.delete(trackId);
      return null;
    }

    // Verify file integrity (size match)
    final int actualFileSize = await file.length();
    if (actualFileSize != entry.fileSize) {
      AppLogger.warning(
          'Cached file size mismatch for $trackId. Metadata: ${entry
              .fileSize}, Actual: $actualFileSize. Recommending re-download.');
      await _metadataStore.delete(trackId); // Invalidate metadata
      await file.delete(); // Delete corrupted file
      return null;
    }

    // Update last accessed time for LRU
    entry.updateAccessedTime();
    await entry.save();

    // For encrypted files, return the proxy URL
    if (entry.isEncrypted) {
      AppLogger.info(
          'Track $trackId is encrypted. Returning proxy URL: http://localhost:${_proxyServer
              .port}/audio/$trackId');
      return 'http://localhost:${_proxyServer.port}/audio/$trackId';
    } else {
      // For unencrypted direct playback, convert the local file path to a file:// URI
      AppLogger.info(
          'Track $trackId is unencrypted. Returning direct file:// URI: ${Uri
              .file(entry.localPath).toString()}');
      return Uri.file(entry.localPath).toString();
    }
  }

  // --- Utility methods (existing) ---
  // The _downloadMp3 method below is a placeholder and should be removed
  // as its functionality is now encapsulated within Mp3CacheHandler.cacheAudio.
  Future<void> _downloadMp3(String url, String trackId, bool encrypt,
      Function(int received, int total)? onProgress) async {
    throw UnimplementedError(
        'This method should be handled by Mp3CacheHandler and is no longer directly used by AudioCacheManager.');
  }

  Future<void> _cleanupCache() async {
    // Implement your cache cleanup logic here, e.g., LRU eviction based on maxCacheSizeBytes
    AppLogger.info('Performing cache cleanup...');
    final allEntries = await _metadataStore.getAll();
    List<CacheEntry> mp3Entries = allEntries
        .where((entry) => !entry.isHls)
        .toList();

    // Sort by last accessed time (oldest first)
    mp3Entries.sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    int currentCacheSize = 0;
    for (var entry in mp3Entries) {
      final file = File(entry.localPath);
      if (await file.exists()) {
        currentCacheSize += await file.length();
      } else {
        // If file doesn't exist, remove its metadata entry
        await _metadataStore.delete(entry.trackId);
        AppLogger.warning(
            'Missing file for cache entry ${entry.trackId}. Metadata removed.');
      }
    }

    // Evict oldest files if cache exceeds max size
    for (var entry in mp3Entries) {
      if (currentCacheSize > maxCacheSizeBytes) {
        final file = File(entry.localPath);
        if (await file.exists()) {
          try {
            await file.delete();
            currentCacheSize -= entry.fileSize;
            await _metadataStore.delete(entry.trackId);
            AppLogger.info(
                'Evicted cached file: ${entry.localPath} (Size: ${entry
                    .fileSize} bytes)');
          } catch (e) {
            AppLogger.error('Failed to evict file ${entry.localPath}: $e');
          }
        }
      } else {
        break; // Stop if cache is within limits
      }
    }
    AppLogger.info('Cache cleanup complete. Current size: ${(currentCacheSize /
        (1024 * 1024)).toStringAsFixed(2)} MB');
  }

  Future<void> clearAudioCache(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized.');
      return;
    }
    final entry = await _metadataStore.get(trackId);
    if (entry != null) {
      if (!entry.isHls) { // Only delete local file if it's not HLS
        final file = File(entry.localPath);
        if (await file.exists()) {
          try {
            await file.delete();
            AppLogger.info(
                'Deleted cached file for $trackId: ${entry.localPath}');
          } catch (e) {
            AppLogger.error('Failed to delete cached file for $trackId: ${entry
                .localPath}, Error: $e');
          }
        }
      }
      await _metadataStore.delete(trackId);
      AppLogger.info('Deleted cache metadata for $trackId.');
    }
  }

  Future<bool> isAudioCached(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning(
          'AudioCacheManager is not initialized. Call init() first.');
      return false;
    }
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry == null) {
      return false;
    }

    // For HLS entries, just check if metadata exists
    if (entry.isHls) {
      return true;
    }

    // For non-HLS, check file existence and validity
    if (!await File(entry.localPath).exists()) {
      await _metadataStore.delete(trackId); // Clean up stale metadata
      return false;
    }
    // Optionally check file size match here as well for full integrity
    return true;
  }

  Future<void> _cleanupPartialDownload(String trackId, bool isHls) async {
    final entry = await _metadataStore.get(trackId);
    if (entry != null) {
      if (!isHls) { // Only attempt to delete local file if it's not HLS
        final file = File(entry.localPath);
        if (await file.exists()) {
          try {
            await file.delete();
            AppLogger.info(
                'Cleaned up partial download file for $trackId: ${entry
                    .localPath}');
          } catch (e) {
            AppLogger.error(
                'Failed to delete partial download file for $trackId: ${entry
                    .localPath}, Error: $e');
          }
        }
      }
      await _metadataStore.delete(trackId);
      AppLogger.info('Cleaned up partial download metadata for $trackId.');
    }
  }
}
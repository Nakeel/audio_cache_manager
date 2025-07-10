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


/// Custom cache manager for music tracks.
/// Phase 1: Basic MP3 caching and direct playback.
class AudioCacheManager {
  // Singleton instance
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal(); // Private constructor for singleton

  // Dependencies
  final CacheMetadataStore _metadataStore = CacheMetadataStore();
  final Mp3CacheHandler _mp3Handler = Mp3CacheHandler();

  // Configuration (only relevant ones for Phase 1)
  late final Duration expirationDuration;
  late final int maxCacheSizeBytes;
  late final String encryptionKey; // Placeholder for future
  late final bool enableEncryption; // Will be false for this phase
  late final LocalProxyServer _localProxyServer; // Will be a stub for this phase

  // Internal flag to ensure init() is called only once successfully
  bool _isInitialized = false;

  // Base directory for all cached files
  late Directory _baseCacheDir;

  /// Configures the cache manager with provided settings.
  /// Must be called before `init()` if custom settings are desired.
  void configure({
    Duration? expirationDuration,
    int? maxCacheSizeBytes,
    String? encryptionKey,
    bool? enableEncryption,
  }) {
    this.expirationDuration = expirationDuration ?? const Duration(days: 30);
    this.maxCacheSizeBytes = maxCacheSizeBytes ?? 2 * 1024 * 1024 * 1024; // 2GB
    this.encryptionKey = encryptionKey ?? 'your-32-byte-secure-key-here-1234';
    this.enableEncryption = enableEncryption ?? false; // Forces false for Phase 1
    // Initialize LocalProxyServer here so it's ready, even if as a stub
    _localProxyServer = LocalProxyServer(); // Initialize the stub for now
    AESHelper.setEncryptionKey(this.encryptionKey); // Still set the key, even if not encrypting
    AppLogger.info('AudioCacheManager configured. Encryption: ${this.enableEncryption}');
  }

  /// Initializes the cache manager.
  /// Must be called once before using the cache manager.
  Future<void> init() async {
    if (_isInitialized) {
      AppLogger.info('AudioCacheManager already initialized. Skipping init().');
      return;
    }

    // Ensure configuration is set. If configure() wasn't called externally, call it now with defaults.
    try {
      // Access a late final field to check if configure() has run
      // ignore: unnecessary_null_comparison
      if (this.enableEncryption == null) {
        configure();
      }
    } catch (_) {
      configure();
    }

    // 1. Initialize base cache directory
    _baseCacheDir = await getApplicationDocumentsDirectory();
    _baseCacheDir = Directory(p.join(_baseCacheDir.path, 'audio_cache'));
    if (!await _baseCacheDir.exists()) {
      await _baseCacheDir.create(recursive: true);
    }
    AppLogger.info('AudioCacheManager: Base cache directory: ${_baseCacheDir.path}');

    // 2. Initialize metadata store (Hive)
    await _metadataStore.init();

    // 3. Initialize proxy server (stubbed for this phase)
    await _localProxyServer.init(
      getCacheEntry: (trackId) => _metadataStore.get(trackId),
      isUserSubscribed: () => false, // Not relevant for phase 1, can be false
      isEncryptionEnabled: () => false, // Not relevant for phase 1, can be false
    );


    // 4. Perform initial cache cleanup (optional, but good practice)
    await _cleanupCache();

    _isInitialized = true;
    AppLogger.info('AudioCacheManager initialized and ready.');
  }

  /// Caches an audio track (MP3 only for Phase 1).
  /// Returns the trackId if successful, null otherwise.
  Future<String?> cacheAudio(
      String originalUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    // For Phase 1, encryption is always false, and HLS is always false
    const bool shouldEncrypt = false;
    const bool isHls = false; // Always false for this phase

    try {
      // Check if already cached and still valid (only based on metadata and existence)
      final existingEntry = await _metadataStore.get(trackId);
      if (existingEntry != null &&
          !existingEntry.isHls && // Ensure it's not an HLS entry (relevant for future phases)
          await File(existingEntry.localPath).exists() &&
          DateTime.now().difference(existingEntry.cachedAt) < expirationDuration) {
        // Also check if existing file size matches metadata (completeness check)
        final int actualFileSize = await File(existingEntry.localPath).length();
        if (actualFileSize == existingEntry.fileSize) {
          AppLogger.info('Audio $trackId already cached and valid. Path: ${existingEntry.localPath}');
          existingEntry.updateAccessedTime();
          await existingEntry.save();
          return trackId;
        } else {
          AppLogger.warning('Cache entry for $trackId found but file size mismatch. Re-downloading.');
          await _cleanupPartialDownload(trackId, isHls); // Clean up inconsistent entry
        }
      }

      // Proceed with download
      final result = await _downloadMp3(originalUrl, trackId, shouldEncrypt, onProgress);

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
          isHls: isHls,
        );
        await _metadataStore.save(newEntry);
        AppLogger.info('Cached audio $trackId: ${newEntry.url} to ${newEntry.localPath}, Size: $fileSize bytes.');
        return trackId;
      }
      return null;
    } catch (e, st) {
      AppLogger.error('Error in cacheAudio for $trackId: $e', error: e, stackTrace: st);
      // Ensure partial downloads are cleaned up on error
      await _cleanupPartialDownload(trackId, isHls);
      return null;
    } finally {
      await _cleanupCache(); // Enforce limits after each caching operation
    }
  }

  /// Handles cleanup of partial downloads (important for integrity).
  Future<void> _cleanupPartialDownload(String trackId, bool isHlsType) async {
    final entry = await _metadataStore.get(trackId); // Get current state
    if (entry != null) {
      final FileSystemEntity fileOrDir;
      if (isHlsType) { // For HLS (future phase), it's a directory
        fileOrDir = Directory(p.join(_baseCacheDir.path, trackId)); // Assuming HLS is trackId-named dir
      } else { // For MP3, it's a file, could be .mp3 or .mp3.enc, or temporary
        // Attempt to delete potential temporary and final files
        final tempFile = File(p.join(_baseCacheDir.path, '$trackId.mp3.tmp'));
        if (await tempFile.exists()) {
          try {
            await tempFile.delete();
            AppLogger.info('Cleaned up temporary file: ${tempFile.path}');
          } catch (e) {
            AppLogger.error('Error deleting temp file ${tempFile.path}: $e');
          }
        }
        final finalFile = File(p.join(_baseCacheDir.path, '$trackId.mp3')); // No .enc for phase 1
        if (await finalFile.exists()) {
          try {
            await finalFile.delete();
            AppLogger.info('Cleaned up final file: ${finalFile.path}');
          } catch (e) {
            AppLogger.error('Error deleting final file ${finalFile.path}: $e');
          }
        }
      }

      await _metadataStore.delete(trackId);
      AppLogger.info('Cleaned up metadata for ${trackId} from Hive due to partial/inconsistent download.');
    }
  }


  /// Downloads and saves an MP3 file with atomic write.
  /// Returns localPath and fileSize if successful, null otherwise.
  Future<Map<String, dynamic>?> _downloadMp3(
      String url,
      String trackId,
      bool shouldEncrypt, // Will be false in this phase
      Function(int received, int total)? onProgress,
      ) async {
    final String tempFileName = '$trackId.mp3.tmp'; // Use a temporary name
    final File tempOutputFile = File(p.join(_baseCacheDir.path, tempFileName));
    final String finalFileName = '$trackId.mp3';
    final File finalOutputFile = File(p.join(_baseCacheDir.path, finalFileName));

    // Ensure no old temp file exists
    if (await tempOutputFile.exists()) {
      await tempOutputFile.delete();
    }
    // Ensure no old final file exists (if re-downloading)
    if (await finalOutputFile.exists()) {
      await finalOutputFile.delete();
    }


    try {
      final Uint8List? downloadedBytes = await _mp3Handler.downloadMp3Bytes(url, onProgress: onProgress);

      if (downloadedBytes == null) {
        AppLogger.warning('MP3 download failed for $trackId from $url.');
        return null;
      }

      // No encryption in Phase 1, so bytesToSave is simply downloadedBytes
      Uint8List bytesToSave = downloadedBytes;

      // Write to temporary file
      await tempOutputFile.writeAsBytes(bytesToSave);
      AppLogger.info('MP3 $trackId downloaded to temporary file: ${tempOutputFile.path}');

      // Verify file size after download to ensure completeness
      final int actualTempFileSize = await tempOutputFile.length();
      if (actualTempFileSize != downloadedBytes.length) {
        AppLogger.error('MP3 download size mismatch for $trackId! Expected ${downloadedBytes.length}, got $actualTempFileSize');
        await tempOutputFile.delete(); // Delete incomplete temp file
        return null;
      }

      // If complete, move/rename to final destination (atomic operation)
      await tempOutputFile.rename(finalOutputFile.path);
      final int finalFileSize = await finalOutputFile.length(); // Get final size

      AppLogger.info('MP3 $trackId saved to ${finalOutputFile.path}, size: $finalFileSize bytes.');
      return {
        'localPath': finalOutputFile.path,
        'fileSize': finalFileSize,
      };
    } catch (e, st) {
      AppLogger.error('Error during _downloadMp3 for $trackId: $e', error: e, stackTrace: st);
      // Ensure temp file is deleted on any error
      if (await tempOutputFile.exists()) {
        await tempOutputFile.delete();
      }
      return null;
    }
  }

  // Placeholder for HLS download (not used in Phase 1)
  Future<Map<String, dynamic>?> _downloadHls(
      String m3u8Url,
      String trackId,
      bool shouldEncrypt,
      Function(int received, int total)? onProgress,
      ) async {
    AppLogger.warning('_downloadHls not implemented for Phase 1.');
    return null;
  }

  /// Gets the playback URL for a cached audio track (direct file path for Phase 1 MP3s).
  /// Returns null if the track is not cached or invalid.
  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final CacheEntry? entry = await _metadataStore.get(trackId);

    if (entry == null) {
      AppLogger.info('Track $trackId not found in cache metadata.');
      return null;
    }

    // For Phase 1, we only handle non-HLS, non-encrypted files.
    if (entry.isHls || entry.isEncrypted) {
      AppLogger.warning('Track $trackId is HLS or encrypted. Not supported in Phase 1 for direct playback.');
      return null;
    }

    final File file = File(entry.localPath);
    if (!await file.exists()) {
      AppLogger.info('Files for $trackId missing on disk. Cleaning up metadata.');
      await _metadataStore.delete(trackId);
      return null;
    }

    // Verify file integrity (size match)
    final int actualFileSize = await file.length();
    if (actualFileSize != entry.fileSize) {
      AppLogger.warning('Cached file size mismatch for $trackId. Metadata: ${entry.fileSize}, Actual: $actualFileSize. Recommending re-download.');
      await _metadataStore.delete(trackId); // Invalidate metadata
      await file.delete(); // Delete corrupted file
      return null;
    }

    // Update last accessed time for LRU
    entry.updateAccessedTime();
    await entry.save();

    // For direct playback, convert the local file path to a file:// URI
    AppLogger.info('DEBUG: Raw localPath from CacheEntry: ${entry.localPath}', name: 'AudioCacheManager');
    final String uriString = Uri.file(entry.localPath).toString();
    AppLogger.info('DEBUG: Formatted URI string (from Uri.file): $uriString', name: 'AudioCacheManager');
    return uriString;
  }

  /// Checks if a track is present and valid in the cache.
  /// Includes file existence and integrity check.
  Future<bool> isAudioCached(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized. Call init() first.');
      return false;
    }

    final entry = await _metadataStore.get(trackId);
    if (entry == null) return false;

    // For Phase 1, we only check for non-HLS, non-encrypted MP3s.
    if (entry.isHls || entry.isEncrypted) {
      AppLogger.warning('isAudioCached for $trackId: Track is HLS or encrypted. Not supported in Phase 1.');
      return false;
    }

    final File file = File(entry.localPath);
    if (!await file.exists()) {
      AppLogger.info('isAudioCached: Files for $trackId missing on disk. Cleaning up metadata.');
      await _metadataStore.delete(trackId);
      return false;
    }

    // Verify file integrity (size match)
    final int actualFileSize = await file.length();
    if (actualFileSize != entry.fileSize) {
      AppLogger.warning('isAudioCached: Cached file size mismatch for $trackId. Inconsistent. Removing.');
      await _metadataStore.delete(trackId); // Invalidate metadata
      await file.delete(); // Delete corrupted file
      return false;
    }

    final bool notExpired = DateTime.now().difference(entry.cachedAt) < expirationDuration;

    return notExpired;
  }

  /// Clears a specific track from cache (files and metadata).
  Future<void> clearAudioCache(String trackId) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized. Call init() first.');
      return;
    }
    final entry = await _metadataStore.get(trackId);
    if (entry != null) {
      await _deleteCachedItem(entry);
      AppLogger.info('Cleared cache for track: $trackId');
    } else {
      AppLogger.info('Track $trackId not found in cache to clear.');
    }
  }

  /// Clears all cached files and metadata.
  Future<void> clearAllCache() async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager is not initialized. Call init() first.');
      return;
    }
    AppLogger.info('Clearing all cache (files and metadata)...');
    await _metadataStore.clear();

    if (await _baseCacheDir.exists()) {
      try {
        await _baseCacheDir.delete(recursive: true);
        await _baseCacheDir.create(recursive: true);
        AppLogger.info('All cached files deleted from disk.');
      } catch (e, st) {
        AppLogger.error('Error deleting base cache directory: $e', error: e, stackTrace: st);
      }
    }
    AppLogger.info('All custom cache cleared.');
  }

  /// Enforce cache size and duration limits.
  Future<void> _cleanupCache() async {
    final allEntries = await _metadataStore.getAll();
    final now = DateTime.now();

    // 1. Remove expired files first and inconsistent files
    for (final entry in allEntries) {
      final File file = File(entry.localPath);
      bool exists = await file.exists();
      int actualSize = exists ? await file.length() : 0;

      if (now.difference(entry.cachedAt) > expirationDuration || !exists || actualSize != entry.fileSize) {
        String reason = '';
        if (now.difference(entry.cachedAt) > expirationDuration) reason = 'expired';
        else if (!exists) reason = 'missing file';
        else if (actualSize != entry.fileSize) reason = 'size mismatch';

        AppLogger.info('Deleting item: ${entry.trackId} because $reason.');
        await _deleteCachedItem(entry);
      }
    }

    int currentTotalSize = _metadataStore.getCurrentCacheSize();

    // 2. Enforce size limit (LRU - Least Recently Used)
    if (currentTotalSize > maxCacheSizeBytes) {
      final List<CacheEntry> sortedItems = await _metadataStore.getAll();
      sortedItems.sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

      for (final entry in sortedItems) {
        if (currentTotalSize <= maxCacheSizeBytes) break;
        AppLogger.info('Deleting LRU item: ${entry.trackId} (Last accessed: ${entry.lastAccessedAt}, Current size: ${currentTotalSize / (1024 * 1024)} MB)');
        await _deleteCachedItem(entry);
        currentTotalSize = _metadataStore.getCurrentCacheSize();
      }
      AppLogger.info('Cache size enforced. Final size: ${currentTotalSize / (1024 * 1024)} MB.');
    }
  }

  /// Helper to delete a cached item (files + metadata).
  Future<void> _deleteCachedItem(CacheEntry entry) async {
    final FileSystemEntity fileOrDir;
    // Handle both file and directory types for deletion
    if (entry.isHls) { // HLS is a directory
      fileOrDir = Directory(entry.localPath);
    } else { // MP3 is a file
      fileOrDir = File(entry.localPath);
    }

    if (await fileOrDir.exists()) {
      try {
        await fileOrDir.delete(recursive: true);
        AppLogger.info('Deleted files for ${entry.trackId} from disk.');
      } catch (e, st) {
        AppLogger.error('Error deleting files for ${entry.trackId}: $e', error: e, stackTrace: st);
      }
    }
    await _metadataStore.delete(entry.trackId); // Use trackId for deletion, not entry.delete()
    AppLogger.info('Deleted metadata for ${entry.trackId} from Hive.');
  }

  /// Disposes resources held by the cache manager.
  Future<void> dispose() async {
    await _metadataStore.close(); // Close Hive box
    // _localProxyServer.dispose() will be called in later phases
    _isInitialized = false;
    AppLogger.info('AudioCacheManager disposed.');
  }
}
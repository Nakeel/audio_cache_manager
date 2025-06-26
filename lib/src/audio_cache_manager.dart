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

import 'dart:async';


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

  // Configuration - now `late final` and initialized in `configure()`
  late final Duration expirationDuration;
  late final int maxCacheSizeBytes;
  late final String encryptionKey; // THIS IS A PLACEHOLDER - LOAD SECURELY
  late final bool enableEncryption;

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
    bool? enableEncryption, // NEW PARAMETER
  }) {
    // Initialize late final fields directly
    this.expirationDuration = expirationDuration ?? const Duration(days: 30);
    this.maxCacheSizeBytes = maxCacheSizeBytes ?? 2 * 1024 * 1024 * 1024; // 2GB
    this.encryptionKey = encryptionKey ?? 'your-32-byte-secure-key-here-1234'; // DEMO ONLY: Replace this!
    this.enableEncryption = enableEncryption ?? false; // Default to false

    // Set the encryption key for AESHelper immediately after configuration
    // This is only relevant if enableEncryption is true and you use AESHelper for encryption
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
    // A simple check for a late final field that *must* be set by configure.
    // Accessing `this.enableEncryption` will throw if `configure` hasn't run.
    try {
      // ignore: unnecessary_null_comparison
      if (this.enableEncryption == null) { // This check relies on the fact that `late final` fields must be initialized.
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
      isEncryptionEnabled: () => enableEncryption, // Pass the new config here
    );

    // 4. Perform initial cache cleanup on startup
    await _cleanupCache();

    _isInitialized = true;
    print('AudioCacheManager initialized and ready. Encryption Enabled: $enableEncryption');
  }

  /// Determines if a given URL is likely an HLS manifest.
  /// This check is more robust than just `endsWith('.m3u8')`.
  bool _determineIsHls(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final query = uri.query;

      // Check common HLS manifest extensions in the path
      if (path.endsWith('.m3u8') || path.endsWith('.m3u')) {
        return true;
      }
      // Check if the path contains known HLS manifest filenames
      if (path.contains('/master.m3u8') || path.contains('/playlist.m3u8') ||
          path.contains('/index.m3u8') || path.contains('/variant.m3u8')) {
        return true;
      }
      // Check for .m3u8 within query parameters as well, sometimes URLs are like baseurl?file=xyz.m3u8
      if (query.contains('.m3u8') || query.contains('.m3u')) {
        return true;
      }
    } catch (e) {
      print('Error parsing URL for HLS detection: $url', );
      // If URL parsing fails, default to false
    }
    return false;
  }

  Future<String?> cacheAudio(
      String originalUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async {
    // Ensure manager is initialized before any operation
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    try {
      // Determine if content is HLS based on URL
      final bool currentIsHls = _determineIsHls(originalUrl);
      // Encryption logic for caching: always encrypt if enableEncryption is true
      final bool shouldEncrypt = enableEncryption;

      // Check if already cached and still valid
      final existingEntry = await _metadataStore.get(trackId);

      // Re-evaluate validity with respect to encryption mode and subscription if existing.
      if (existingEntry != null &&
          await (existingEntry.isHls ? Directory(existingEntry.localPath).exists() : File(existingEntry.localPath).exists()) &&
          DateTime.now().difference(existingEntry.cachedAt) < expirationDuration) {

        // Crucial: If encryption is enabled, ensure the existing entry's encryption status matches expectations.
        // If enableEncryption is true, but the existing entry is NOT encrypted, it's a mismatch.
        // This can happen if enableEncryption was false, and then changed to true.
        if (enableEncryption && !existingEntry.isEncrypted) {
          print('Cache entry for $trackId found but encryption status mismatch. Re-downloading.');
          await _cleanupPartialDownload(trackId, existingEntry.isHls); // Clean up old unencrypted entry
          // Continue to download new (encrypted) version below
        } else if (!enableEncryption && existingEntry.isEncrypted) {
          // If encryption is now disabled, but existing entry IS encrypted, re-download unencrypted version
          print('Cache entry for $trackId found but encryption status mismatch (encryption now disabled). Re-downloading.');
          await _cleanupPartialDownload(trackId, existingEntry.isHls); // Clean up old encrypted entry
          // Continue to download new (unencrypted) version below
        } else {
          // Valid and encryption status matches
          print('Audio $trackId already cached and valid. Path: ${existingEntry.localPath}, Encrypted: ${existingEntry.isEncrypted}');
          existingEntry.updateAccessedTime();
          await existingEntry.save();
          return trackId;
        }
      }

      String? finalLocalPath;
      int fileSize = 0;

      if (currentIsHls) {
        final result = await _downloadHls(originalUrl, trackId, shouldEncrypt, onProgress);
        if (result != null) {
          finalLocalPath = result['localPath'];
          fileSize = result['fileSize'];
        }
      } else {
        final result = await _downloadMp3(originalUrl, trackId, shouldEncrypt, onProgress);
        if (result != null) {
          finalLocalPath = result['localPath'];
          fileSize = result['fileSize'];
        }
      }

      if (finalLocalPath != null) {
        final newEntry = CacheEntry(
          trackId: trackId,
          url: originalUrl,
          localPath: finalLocalPath,
          cachedAt: DateTime.now(),
          lastAccessedAt: DateTime.now(),
          fileSize: fileSize,
          isEncrypted: shouldEncrypt, // Store the actual encryption status of the cached file
          isHls: currentIsHls,
        );
        await _metadataStore.save(newEntry);
        print('Cached audio $trackId: ${newEntry.url} to ${newEntry.localPath}, Encrypted: $shouldEncrypt, Size: $fileSize bytes.');
        return trackId;
      }
      return null;
    } catch (e, st) {
      print('Error in cacheAudio for $trackId: $e', );
      final bool determinedIsHlsForCleanup = _determineIsHls(originalUrl); // Re-determine for cleanup
      await _cleanupPartialDownload(trackId, determinedIsHlsForCleanup);
      return null;
    } finally {
      await _cleanupCache(); // Enforce limits after each caching operation
    }
  }

  Future<void> _cleanupPartialDownload(String trackId, bool isHlsDuringDownload) async {
    final entry = await _metadataStore.get(trackId);
    if (entry != null) {
      final bool typeForCleanup = entry.isHls; // Use the stored type for cleanup
      final FileSystemEntity fileOrDir;
      if (typeForCleanup) {
        fileOrDir = Directory(entry.localPath);
      } else {
        fileOrDir = File(entry.localPath);
      }

      if (await fileOrDir.exists()) {
        try {
          await fileOrDir.delete(recursive: true);
          print('Cleaned up files for ${entry.trackId} from disk.');
        } catch (e, st) {
          print('Error deleting files for ${entry.trackId} during cleanup: $e',);
        }
      }
      await _metadataStore.delete(trackId); // Delete metadata regardless
      print('Cleaned up metadata for ${entry.trackId} from Hive during cleanup.');
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
  /// This method is crucial for how HLS content is cached and prepared for local proxy serving.
  Future<Map<String, dynamic>?> _downloadHls(
      String m3u8Url,
      String trackId,
      bool shouldEncrypt,
      Function(int received, int total)? onProgress,
      ) async {
    final String trackCacheDirPath = p.join(_baseCacheDir.path, trackId);
    final Directory trackDir = Directory(trackCacheDirPath);

    if (await trackDir.exists()) {
      await trackDir.delete(recursive: true);
    }
    await trackDir.create(recursive: true);
    print('Created HLS cache directory: ${trackDir.path}');

    // 1. Download Master M3U8 Manifest
    try {
      final Response<String> manifestResponse = await _dio.get(
        m3u8Url,
        options: Options(responseType: ResponseType.plain),
      );
      final String masterM3u8Content = manifestResponse.data!;
      final String masterM3u8FileName = p.basename(Uri.parse(m3u8Url).path);
      final File localMasterM3u8File = File(p.join(trackDir.path, masterM3u8FileName));
      await localMasterM3u8File.writeAsString(masterM3u8Content);
      print('HLS master manifest downloaded: ${localMasterM3u8File.path}');

      // 2. Parse Manifests and Collect All Segment/Sub-playlist URLs
      Set<String> allMediaUrlsToDownload = {};
      Queue<String> manifestsToParse = Queue();
      manifestsToParse.add(m3u8Url);

      Set<String> processedManifestUrls = {};

      while (manifestsToParse.isNotEmpty) {
        final currentManifestUrl = manifestsToParse.removeFirst();
        if (processedManifestUrls.contains(currentManifestUrl)) {
          continue;
        }
        processedManifestUrls.add(currentManifestUrl);

        String currentManifestContent;
        if (currentManifestUrl == m3u8Url) {
          currentManifestContent = masterM3u8Content;
        } else {
          try {
            final subManifestResponse = await _dio.get(
              currentManifestUrl,
              options: Options(responseType: ResponseType.plain),
            );
            currentManifestContent = subManifestResponse.data!;
            final subM3u8FileName = p.basename(Uri.parse(currentManifestUrl).path);
            final File localSubM3u8File = File(p.join(trackDir.path, subM3u8FileName));
            await localSubM3u8File.writeAsString(currentManifestContent);
            print('Downloaded sub-manifest: ${localSubM3u8File.path}');
          } on DioException catch (e) {
            print('Error downloading sub-manifest $currentManifestUrl: ${e.message}');
            continue;
          }
        }

        final lines = currentManifestContent.split('\n');
        final baseUri = Uri.parse(currentManifestUrl);

        for (final line in lines) {
          final trimmedLine = line.trim();
          if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
            final resolvedUrl = baseUri.resolve(trimmedLine).toString();
            if (resolvedUrl.endsWith('.m3u8') && !processedManifestUrls.contains(resolvedUrl)) {
              manifestsToParse.add(resolvedUrl);
            } else if (resolvedUrl.endsWith('.ts') || resolvedUrl.contains('.mp4') || resolvedUrl.contains('.aac')) {
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
          final String mediaFileName = p.basename(Uri.parse(mediaUrl).path);
          final String localMediaPath = p.join(trackDir.path, mediaFileName);

          try {
            final Response<Uint8List> mediaResponse = await _dio.get<Uint8List>(
              mediaUrl,
              options: Options(responseType: ResponseType.bytes),
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
                onProgress(downloadedCount, totalItems);
              }
            } else {
              print('Failed to download media $mediaUrl. Status: ${mediaResponse.statusCode}');
            }
          } on DioException catch (e, st) {
            print('DioError downloading media $mediaUrl: ${e.message}', );
          } catch (e, st) {
            print('Error downloading media $mediaUrl: $e', );
          }
        }());
      }
      await Future.wait(downloadFutures);
      print('All HLS media segments downloaded and processed for track $trackId.');

      // 4. Rewrite All Local M3U8 Manifests to point to Local Proxy Server
      final List<File> localManifestFiles = trackDir.listSync(recursive: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.m3u8'))
          .toList();

      for (final localManifestFile in localManifestFiles) {
        String currentManifestContent = await localManifestFile.readAsString();
        final originalManifestUrl = localManifestFile.path.replaceFirst(trackDir.path, p.dirname(m3u8Url)); // This is tricky. Better to pass original URL context.

        // Better: when parsing original manifests, store their original URLs
        // and use those as the base for resolving relative paths during rewriting.
        // For now, let's assume we can reconstruct the base or rely on relative rewriting.

        // Split content into lines and map each line to its new, proxied version
        currentManifestContent = currentManifestContent.split('\n').map((line) {
          final trimmedLine = line.trim();
          if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) {
            return line; // Return comments or empty lines as is
          }

          // Try to parse as a URI to handle both absolute and relative paths
          Uri? parsedUri;
          try {
            // Attempt to parse as relative first, then absolute if that fails
            // This ensures relative paths are not incorrectly treated as absolute
            parsedUri = Uri.tryParse(trimmedLine);
            if (parsedUri != null && parsedUri.hasScheme) { // It's an absolute URL
              // This is the case your regex was trying to handle
            } else { // It's a relative path, resolve against the original manifest's base
              // You need the original base URL of *this specific manifest* to correctly resolve relative paths.
              // This is the missing piece if you have nested manifests with relative paths.
              // For simplicity, let's assume all relative paths are segment/sub-playlist names.
            }
          } catch (_) {
            // Ignore parsing errors, treat as non-URI if it's just a file name
            parsedUri = null;
          }

          String fileNameFromLine;
          if (parsedUri != null && parsedUri.hasScheme) { // It was an absolute URL
            fileNameFromLine = p.basename(parsedUri.path);
          } else { // It was a relative path or just a filename
            fileNameFromLine = p.basename(trimmedLine.split('?')[0]); // Remove query params for filename
          }


          if (fileNameFromLine.endsWith('.m3u8')) {
            // This is a sub-playlist or the master playlist reference
            // Ensure the fileName passed is just the manifest filename (e.g., 'variant.m3u8')
            return _localProxyServer.getHlsPlaylistProxyUrl(trackId, fileNameFromLine);
          } else if (fileNameFromLine.endsWith('.ts') || fileNameFromLine.endsWith('.mp4') || fileNameFromLine.endsWith('.aac')) {
            // This is a media segment
            // Ensure the fileName passed is just the segment filename (e.g., 'segment0001.ts')
            return _localProxyServer.getHlsSegmentProxyUrl(trackId, fileNameFromLine);
          }

          return line; // Return original line if not a URL to replace
        }).join('\n');

        await localManifestFile.writeAsString(currentManifestContent);
        print('Rewritten HLS manifest saved: ${localManifestFile.path}');
      }

      final int totalHlsSize = await _calculateDirectorySize(trackDir);
      print('HLS track $trackId total cached size: $totalHlsSize bytes.');

      return {
        'localPath': trackDir.path,
        'fileSize': totalHlsSize,
      };
    } catch (e, st) {
      print('Error in _downloadHls for $trackId: $e', );
      // Clean up the partially created directory if an error occurs during download
      if (await trackDir.exists()) {
        try {
          await trackDir.delete(recursive: true);
          print('Cleaned up partial HLS download directory for $trackId.');
        } catch (deleteError, deleteSt) {
          print('Error cleaning up HLS directory for $trackId: $deleteError', );
        }
      }
      return null;
    }
  }

  /// Gets the playback URL for a cached audio track.
  /// Returns a local proxy URL for HLS and encrypted MP3s, or a direct file path for unencrypted MP3s.
  /// Returns null if the track is not cached, invalid, or access is denied due to subscription/encryption settings.
  Future<String?> getPlaybackUrl(String trackId) async {
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final CacheEntry? entry = await _metadataStore.get(trackId);

    if (entry == null) {
      print('Track $trackId not found in cache metadata.');
      return null;
    }

    // NEW LOGIC: Access control based on enableEncryption and subscription
    if (enableEncryption && !isUserSubscribed) {
      print('Access denied to cached data for $trackId: Encryption is enabled, but user is not subscribed.');
      // Optionally, you might want to clear this specific cached item if access is denied,
      // especially if it's encrypted and an unsubscribed user shouldn't even have it.
      // await clearAudioCache(trackId); // Consider if this is desired behavior
      return null;
    }

    // Verify files/directories exist on disk
    final bool filesExist = entry.isHls
        ? await Directory(entry.localPath).exists()
        : await File(entry.localPath).exists();

    if (!filesExist) {
      print('Files for $trackId missing on disk. Cleaning up metadata.');
      await _metadataStore.delete(trackId);
      return null;
    }

    // Update last accessed time for LRU
    entry.updateAccessedTime();
    await entry.save();

    if (entry.isHls) {
      // For HLS, we pass the original master m3u8 file name to the proxy.
      // The proxy will serve the locally rewritten version of that file.
      final String masterM3u8FileName = p.basename(Uri.parse(entry.url).path);
      return _localProxyServer.getHlsPlaylistProxyUrl(trackId, masterM3u8FileName);
    } else {
      // For MP3: return proxy URL if encrypted, else direct file path.
      return entry.isEncrypted ? _localProxyServer.getMp3ProxyUrl(trackId) : entry.localPath;
    }
  }

  /// Checks if a track is present and valid in the cache.
  /// Includes new logic for subscription-based access if encryption is enabled.
  Future<bool> isAudioCached(String trackId) async {
    // Ensure manager is initialized
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return false;
    }

    final entry = await _metadataStore.get(trackId); // Get by trackId
    if (entry == null) return false;

    // NEW LOGIC: Access control based on enableEncryption and subscription
    if (enableEncryption && !isUserSubscribed) {
      print('isAudioCached for $trackId: Encryption is enabled, but user is not subscribed. Returning false.');
      return false; // Treat as not cached if user cannot access
    }

    // Check if the actual files exist and are within expiration
    final bool filesExist = entry.isHls
        ? await Directory(entry.localPath).exists()
        : await File(entry.localPath).exists();

    final bool notExpired = DateTime.now().difference(entry.cachedAt) < expirationDuration;

    // Also check for encryption status consistency if encryption is enabled
    final bool encryptionStatusMatches = !enableEncryption || (enableEncryption && entry.isEncrypted);
    if (!encryptionStatusMatches) {
      print('isAudioCached for $trackId: Encryption status mismatch. Cache entry is not encrypted but encryption is enabled, or vice versa.');
      // Optionally delete the inconsistent cache entry here or signal re-download in cacheAudio.
      return false; // Treat as not cached if encryption status is inconsistent
    }

    return filesExist && notExpired && encryptionStatusMatches;
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



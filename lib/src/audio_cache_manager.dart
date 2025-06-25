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

      // If the URL contains an HLS specific identifier (like /hls/ or /live/)
      // and ends with a common video/audio extension, it might be an HLS source
      // where the manifest name is implied or generated.
      // This is a heuristic, be careful with it.
      if ((path.contains('/hls/') || path.contains('/live/')) &&
          (path.endsWith('.mp4') || path.endsWith('.m4a') || path.endsWith('.aac') || path.endsWith('.ts'))) {
        // Example: https://example.com/hls/audio.m4a (where m4a is actually a manifest endpoint)
        // This is less common but can occur with some CDN setups.
        // If this leads to false positives, remove this part.
        return true;
      }

    } catch (e) {
      print('Error parsing URL for HLS detection: $url, error: $e');
      // If URL parsing fails, default to false
    }
    return false;
  }

  Future<String?> cacheAudio(
      String originalUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
        // bool isHls = false, // <-- This parameter is now removed
      }) async {
    // Ensure manager is initialized before any operation
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    try {
      // Check if already cached and still valid
      final existingEntry = await _metadataStore.get(trackId);
      final bool currentIsHls = _determineIsHls(originalUrl); // Determine HLS status here

      if (existingEntry != null &&
          await (existingEntry.isHls ? Directory(existingEntry.localPath).exists() : File(existingEntry.localPath).exists()) &&
          DateTime.now().difference(existingEntry.cachedAt) < expirationDuration) {
        print('Audio $trackId already cached and valid. Path: ${existingEntry.localPath}');
        // Update lastAccessedAt as caching implies access
        existingEntry.updateAccessedTime();
        await existingEntry.save();
        return trackId;
      }

      final bool shouldEncrypt = isUserSubscribed;

      String? finalLocalPath;
      int fileSize = 0;

      if (currentIsHls) { // Use the determined HLS status
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
          isHls: currentIsHls, // Store the determined HLS status
        );
        await _metadataStore.save(newEntry); // Save with trackId as key
        print('Cached audio $trackId: ${newEntry.url} to ${newEntry.localPath}, Encrypted: $shouldEncrypt, Size: $fileSize bytes.');
        return trackId;
      }
      return null;
    } catch (e) {
      print('Error in cacheAudio for $trackId: $e');
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
      // Use the 'isHls' from the CacheEntry if available, otherwise fallback to the
      // 'isHlsDuringDownload' which was passed to the cacheAudio function for this specific call.
      // This fallback is crucial if the entry itself wasn't successfully saved to Hive.
      final bool typeForCleanup = entry.isHls ?? isHlsDuringDownload;

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
        } catch (e) {
          print('Error deleting files for ${entry.trackId} during cleanup: $e');
        }
      }
      await _metadataStore.delete(trackId);
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
    final Response<String> manifestResponse = await _dio.get(
      m3u8Url,
      options: Options(responseType: ResponseType.plain),
    );
    final String masterM3u8Content = manifestResponse.data!;
    final String masterM3u8FileName = p.basename(Uri.parse(m3u8Url).path); // Get clean filename from URL path
    final File localMasterM3u8File = File(p.join(trackDir.path, masterM3u8FileName));
    await localMasterM3u8File.writeAsString(masterM3u8Content);
    print('HLS master manifest downloaded: ${localMasterM3u8File.path}');

    // 2. Parse Manifests and Collect All Segment/Sub-playlist URLs
    // Use a Queue to handle recursive parsing of nested M3U8s
    Set<String> allMediaUrlsToDownload = {};
    Queue<String> manifestsToParse = Queue();
    manifestsToParse.add(m3u8Url); // Start with the master manifest URL

    Set<String> processedManifestUrls = {}; // Keep track of processed manifest URLs to avoid cycles/re-downloading

    // Aggregate initial total bytes for progress calculation (approximate)
    int totalBytesToDownload = 0;

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
        final String mediaFileName = p.basename(Uri.parse(mediaUrl).path); // Get clean filename from URL path
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
      }());
    }
    await Future.wait(downloadFutures);
    print('All HLS media segments downloaded and processed for track $trackId.');

    // 4. Rewrite All Local M3U8 Manifests to point to Local Proxy Server
    // Iterate through all manifest files saved locally in this track's directory
    final List<File> localManifestFiles = trackDir.listSync(recursive: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.m3u8'))
        .toList();

    for (final localManifestFile in localManifestFiles) {
      String currentManifestContent = await localManifestFile.readAsString();

      // Iterate through lines to find and replace URLs with proxy URLs
      currentManifestContent = currentManifestContent.split('\n').map((line) {
        final trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          // This regex aims to match common HLS media segment and sub-playlist URLs.
          // It handles URLs that might have query parameters.
          final urlMatch = RegExp(r'^(https?://.*?\.(?:ts|m3u8|mp4|aac)(\?.*)?)$').firstMatch(trimmedLine);

          if (urlMatch != null) {
            final String originalMatchedUrl = urlMatch.group(0)!; // The entire matched URL
            final String fileName = p.basename(Uri.parse(originalMatchedUrl).path); // Clean filename from the matched URL

            if (originalMatchedUrl.endsWith('.m3u8')) {
              // This is a sub-playlist or the master playlist reference
              return _localProxyServer.getHlsPlaylistProxyUrl(trackId, fileName);
            } else {
              // This is a media segment
              return _localProxyServer.getHlsSegmentProxyUrl(trackId, fileName);
            }
          }
          // If the line is a relative path (e.g., 'segment0001.ts' or 'low.m3u8')
          else if (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.m3u8') || trimmedLine.endsWith('.mp4') || trimmedLine.endsWith('.aac')) {
            final String fileName = p.basename(trimmedLine.split('?')[0]); // Get filename without query params
            if (trimmedLine.endsWith('.m3u8')) {
              return _localProxyServer.getHlsPlaylistProxyUrl(trackId, fileName);
            } else {
              return _localProxyServer.getHlsSegmentProxyUrl(trackId, fileName);
            }
          }
        }
        return line; // Return original line if not a URL to replace
      }).join('\n');

      // Overwrite the local manifest file with the rewritten content.
      // This means the file on disk (e.g., master.m3u8 or sub.m3u8) will contain proxy URLs.
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
    if (!_isInitialized) {
      print('AudioCacheManager is not initialized. Call init() first.');
      return null;
    }

    final CacheEntry? entry = await _metadataStore.get(trackId);

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



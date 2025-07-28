import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/models/hls_segment_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';

class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  final LocalProxyServer _proxyServer;
  final CacheMetadataStore _metadataStore;
  final dynamic _internetChecker; // NEW: Inject InternetChecker

  HlsCacheHandler({
    required LocalProxyServer proxyServer,
    required CacheMetadataStore metadataStore,
    required dynamic internetChecker, // NEW: Add to constructor
  })  : _proxyServer = proxyServer,
        _metadataStore = metadataStore,
        _internetChecker = internetChecker; // Initialize InternetChecker

  /// Caches an HLS stream, downloading a single chosen variant and its segments.
  /// It supports resuming incomplete downloads and stores segment-level metadata.
  /// Returns the local path to the rewritten master manifest.
  Future<String?> cacheHls(
      String hlsUrl,
      String cacheBaseDirPath,
      String trackId, {
        Function(int received, int total)? onProgress,
        bool encrypt = false,
      }) async {
    AppLogger.info('Attempting to cache HLS stream: $hlsUrl for track $trackId. Encrypt: $encrypt', name: 'HlsCacheHandler');

    final Uri hlsUri = Uri.parse(hlsUrl);
    final String hlsTrackDirPath = p.join(cacheBaseDirPath, trackId);
    final Directory hlsTrackDir = Directory(hlsTrackDirPath);

    // Retrieve existing cache entry to resume download, if any
    CacheEntry? existingEntry = await _metadataStore.get(trackId);
    List<HlsSegmentEntry> segmentsToCache = [];
    String? masterManifestContent;
    String? mediaPlaylistContent;
    Uri? mediaPlaylistBaseUri;
    String? mediaPlaylistFileName;
    String? masterManifestFileName;

    try {
      if (!await hlsTrackDir.exists()) {
        await hlsTrackDir.create(recursive: true);
        AppLogger.info('Created HLS cache directory: ${hlsTrackDir.path}', name: 'HlsCacheHandler');
      }

      // 1. Download or load Master Manifest
      if (existingEntry != null && existingEntry.hlsMasterManifestFileName != null) {
        final File localMasterManifestFile = File(p.join(hlsTrackDirPath, existingEntry.hlsMasterManifestFileName!));
        if (await localMasterManifestFile.exists()) {
          masterManifestContent = await localMasterManifestFile.readAsString();
          AppLogger.info('Loaded existing master manifest for $trackId from ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
        }
      }

      // Check network before trying to download master manifest
      if (masterManifestContent == null) {
        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet to download master manifest for $trackId. Cannot proceed with caching.', name: 'HlsCacheHandler');
          return null; // Cannot cache without master manifest
        }
        AppLogger.info('Downloading master manifest from $hlsUrl', name: 'HlsCacheHandler');
        final http.Response masterManifestResponse = await http.get(hlsUri);
        if (masterManifestResponse.statusCode != 200) {
          AppLogger.error('Failed to download master manifest: ${masterManifestResponse.statusCode}', name: 'HlsCacheHandler');
          throw Exception('Failed to download master manifest');
        }
        masterManifestContent = masterManifestResponse.body;
      }
      masterManifestFileName = p.basename(hlsUri.path);


      Uri baseUri = hlsUri; // Base URI for resolving relative paths in manifest

      // Parse master manifest to find variants
      List<String> mediaPlaylistUrls = [];
      List<String> lines = masterManifestContent.split('\n');
      for (int i = 0; i < lines.length; i++) {
        String line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          if (i + 1 < lines.length) {
            String uriLine = lines[i + 1].trim();
            if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
              mediaPlaylistUrls.add(uriLine);
            }
          }
        }
      }

      String? selectedMediaPlaylistUrl;
      // Select the first media playlist found (or the original URL if no variants)
      if (mediaPlaylistUrls.isNotEmpty) {
        selectedMediaPlaylistUrl = _resolveUri(baseUri, mediaPlaylistUrls.first).toString();
        AppLogger.info('Selected media playlist: $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
      } else {
        AppLogger.info('No EXT-X-STREAM-INF found, assuming single media playlist from original URL.', name: 'HlsCacheHandler');
        selectedMediaPlaylistUrl = hlsUrl; // Treat the original URL as the media playlist
      }
      mediaPlaylistFileName = p.basename(Uri.parse(selectedMediaPlaylistUrl).path);


      // 2. Download or load Media Playlist (the chosen variant's playlist)
      final String localMediaPlaylistPath = p.join(hlsTrackDirPath, mediaPlaylistFileName);
      if (existingEntry != null && existingEntry.hlsMediaPlaylistFileName != null) {
        final File localMediaPlaylistFile = File(localMediaPlaylistPath);
        if (await localMediaPlaylistFile.exists()) {
          mediaPlaylistContent = await localMediaPlaylistFile.readAsString();
          AppLogger.info('Loaded existing media playlist for $trackId from ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');
        }
      }

      // Check network before trying to download media playlist
      if (mediaPlaylistContent == null) {
        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet to download media playlist for $trackId. Cannot proceed with caching.', name: 'HlsCacheHandler');
          return null; // Cannot cache without media playlist
        }
        AppLogger.info('Downloading media playlist from $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
        final http.Response mediaPlaylistResponse = await http.get(Uri.parse(selectedMediaPlaylistUrl));
        if (mediaPlaylistResponse.statusCode != 200) {
          AppLogger.error('Failed to download media playlist: ${mediaPlaylistResponse.statusCode}', name: 'HlsCacheHandler');
          throw Exception('Failed to download media playlist');
        }
        mediaPlaylistContent = mediaPlaylistResponse.body;
      }
      mediaPlaylistBaseUri = Uri.parse(selectedMediaPlaylistUrl); // Base URI for resolving segments


      // 3. Prepare segments for download/resumption
      List<String> mediaPlaylistLines = mediaPlaylistContent.split('\n');
      List<String> allSegmentOriginalUrls = [];

      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#') && !trimmedLine.startsWith('#EXT')) {
          allSegmentOriginalUrls.add(_resolveUri(mediaPlaylistBaseUri, trimmedLine).toString());
        }
      }

      // Initialize segmentsToCache list from existing entry or create new ones
      if (existingEntry != null && existingEntry.hlsSegments != null) {
        // Use existing segments and update their status
        segmentsToCache = List.from(existingEntry.hlsSegments!);
        // Ensure all segments from the current manifest are in our list, add new ones if manifest changed
        for (String originalUrl in allSegmentOriginalUrls) {
          if (!segmentsToCache.any((s) => s.originalUrl == originalUrl)) {
            final String relativeSegmentPath = _getRelativeSegmentPath(mediaPlaylistBaseUri, Uri.parse(originalUrl));
            segmentsToCache.add(HlsSegmentEntry(originalUrl: originalUrl, localRelativePath: relativeSegmentPath));
          }
        }
      } else {
        // Create new HlsSegmentEntry for each segment
        for (String originalUrl in allSegmentOriginalUrls) {
          final String relativeSegmentPath = _getRelativeSegmentPath(mediaPlaylistBaseUri, Uri.parse(originalUrl));
          segmentsToCache.add(HlsSegmentEntry(originalUrl: originalUrl, localRelativePath: relativeSegmentPath));
        }
      }

      int totalSegments = segmentsToCache.length;
      int downloadedSegmentsCount = segmentsToCache.where((s) => s.isComplete).length;
      int currentTotalBytes = segmentsToCache.where((s) => s.isComplete).fold(0, (sum, s) => sum + s.totalBytes);

      // Report initial progress
      if (onProgress != null) {
        onProgress(downloadedSegmentsCount, totalSegments);
      }

      // 4. Download/Resume Segments sequentially
      for (int i = 0; i < segmentsToCache.length; i++) {
        HlsSegmentEntry segment = segmentsToCache[i];

        if (segment.isComplete) {
          AppLogger.info('Segment ${segment.localRelativePath} already complete. Skipping download.', name: 'HlsCacheHandler');
          continue; // Skip if already complete
        }

        // NEW: Check network connectivity before attempting to download each segment
        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet connection. Halting HLS segment download for track $trackId. Will continue with hybrid playback.', name: 'HlsCacheHandler');
          break; // Exit the loop gracefully
        }

        AppLogger.info('Processing segment: ${segment.originalUrl}', name: 'HlsCacheHandler');
        final Uri segmentUri = Uri.parse(segment.originalUrl);
        final File segmentFile = File(p.join(hlsTrackDirPath, segment.localRelativePath));

        // Ensure segment directory exists if it's nested
        if (!await segmentFile.parent.exists()) {
          await segmentFile.parent.create(recursive: true);
        }

        bool segmentDownloadSuccess = false;
        for (int retry = 0; retry < _maxSegmentRetries; retry++) {
          // NEW: Check network connectivity before each retry
          if (!await _internetChecker.hasInternet) {
            AppLogger.warning('No internet connection during retry for segment ${segment.localRelativePath}. Halting HLS segment download.', name: 'HlsCacheHandler');
            break; // Exit retry loop if no internet
          }

          try {
            // Check for partial download and set Range header
            int startByte = 0;
            if (await segmentFile.exists()) {
              startByte = await segmentFile.length();
              if (startByte > 0 && startByte < segment.totalBytes) {
                AppLogger.info('Resuming download for segment ${segment.localRelativePath} from byte $startByte', name: 'HlsCacheHandler');
              } else if (startByte == segment.totalBytes && segment.totalBytes > 0) {
                // File exists and matches expected total bytes, mark as complete and skip
                segment = segment.copyWith(isComplete: true, downloadedBytes: startByte);
                segmentsToCache[i] = segment; // Update the list
                segmentDownloadSuccess = true;
                AppLogger.info('Segment ${segment.localRelativePath} already fully downloaded. Skipping.', name: 'HlsCacheHandler');
                break;
              } else if (startByte > 0 && segment.totalBytes == 0) {
                // Potentially incomplete but totalBytes unknown, attempt resume
                AppLogger.info('Segment ${segment.localRelativePath} exists with $startByte bytes, but total unknown. Attempting resume.', name: 'HlsCacheHandler');
              }
            }

            final Map<String, String> headers = {};
            if (startByte > 0) {
              headers['Range'] = 'bytes=$startByte-';
            }

            final http.Response segmentResponse = await http.get(segmentUri, headers: headers);

            if (segmentResponse.statusCode == 200 || segmentResponse.statusCode == 206) { // 206 for partial content
              Uint8List segmentBytes = segmentResponse.bodyBytes;
              int newDownloadedBytes = startByte + segmentBytes.length;
              int segmentTotalBytes = segmentResponse.contentLength ?? 0; // Get total from Content-Length header

              // If it's a 200 response and we had a startByte, it means server didn't support range.
              // In this case, we should re-download the whole file.
              if (segmentResponse.statusCode == 200 && startByte > 0) {
                AppLogger.warning('Server did not support Range requests for ${segment.localRelativePath}. Re-downloading from start.', name: 'HlsCacheHandler');
                await segmentFile.delete(); // Delete partial file
                startByte = 0; // Reset start byte
                newDownloadedBytes = segmentBytes.length;
              }

              if (encrypt) {
                AppLogger.info('Encrypting HLS segment: ${segmentFile.path} for track $trackId', name: 'HlsCacheHandler');
                segmentBytes = AESHelper.encrypt(segmentBytes); // Encrypt segment bytes
              }

              // Append or write from start
              if (startByte > 0 && segmentResponse.statusCode == 206) {
                await segmentFile.writeAsBytes(segmentBytes, mode: FileMode.append);
              } else {
                await segmentFile.writeAsBytes(segmentBytes);
              }

              segment = segment.copyWith(
                downloadedBytes: newDownloadedBytes,
                totalBytes: segmentTotalBytes > 0 ? segmentTotalBytes : newDownloadedBytes, // If totalBytes unknown, assume current
                isComplete: (segmentTotalBytes > 0 && newDownloadedBytes >= segmentTotalBytes) || (segmentTotalBytes == 0 && newDownloadedBytes > 0), // Consider complete if total known and matched, or if some bytes downloaded and total unknown (implies full download)
              );
              segmentsToCache[i] = segment; // Update the list
              AppLogger.info('Saved segment: ${segment.localRelativePath}, downloaded: ${segment.downloadedBytes}/${segment.totalBytes} bytes, complete: ${segment.isComplete}', name: 'HlsCacheHandler');
              segmentDownloadSuccess = true;

              // Update total cached size for progress reporting
              currentTotalBytes += segmentBytes.length;

              break; // Segment downloaded successfully
            } else {
              AppLogger.warning('Failed to download segment ${segment.localRelativePath}: ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
            }
          } on SocketException catch (e, st) {
            AppLogger.warning('SocketException during segment download for ${segment.localRelativePath}: $e. This often indicates network loss. Halting download.', name: 'HlsCacheHandler');
            // If a SocketException occurs, it's a strong indicator of network loss.
            // Break from the retry loop and the main download loop.
            segmentDownloadSuccess = false; // Ensure it's marked as not successful
            break;
          } catch (e, st) {
            AppLogger.error('Error downloading segment ${segment.localRelativePath}: $e. Retrying...', error: e, stackTrace: st, name: 'HlsCacheHandler');
          }
          await Future.delayed(_retryDelay);
        }

        if (!segmentDownloadSuccess) {
          AppLogger.error('Failed to download segment after $_maxSegmentRetries retries or network lost: ${segment.originalUrl}', name: 'HlsCacheHandler');
          // Do NOT throw an exception here. We want to continue caching other segments
          // and rely on the manifest rewriting to point to the original URL for this failed segment.
          // Mark segment as incomplete if it's not already.
          segment = segment.copyWith(isComplete: false);
          segmentsToCache[i] = segment;
          // If the failure was due to network loss, we should stop further downloads.
          if (!await _internetChecker.hasInternet) {
            AppLogger.warning('Network still unavailable after segment failure. Stopping further HLS segment downloads.', name: 'HlsCacheHandler');
            break; // Break the main segment loop
          }
        }

        // Update progress for each segment processed (whether downloaded or skipped)
        downloadedSegmentsCount = segmentsToCache.where((s) => s.isComplete).length;
        if (onProgress != null) {
          onProgress(downloadedSegmentsCount, totalSegments);
        }

        // Save metadata after each segment to ensure progress is persisted
        await _metadataStore.save(
          existingEntry?.copyWith(
            hlsSegments: segmentsToCache,
            fileSize: currentTotalBytes, // Update total size based on completed segments
          ) ?? CacheEntry(
            trackId: trackId,
            originalUrl: hlsUrl,
            filePath: '', // Not applicable for HLS
            timestamp: DateTime.now(),
            fileSize: currentTotalBytes,
            isEncrypted: encrypt,
            etag: '', // HLS doesn't typically use ETag for segments
            lastModified: '', // HLS doesn't typically use Last-Modified for segments
            contentType: 'application/x-mpegURL',
            proxyUrl: _proxyServer.getProxyUrl(trackId), // Main proxy URL for the track
            isHls: true,
            hlsLocalPath: hlsTrackDirPath,
            hlsMasterManifestFileName: masterManifestFileName,
            hlsMediaPlaylistFileName: mediaPlaylistFileName,
            hlsSegments: segmentsToCache,
          ),
        );
      } // End of segment download loop


      // 5. Rewrite Media Playlist to point to local proxy URLs for cached segments, or original for others
      String finalMediaPlaylistContent = '';
      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#') && !trimmedLine.startsWith('#EXT')) {
          final Uri segmentOriginalUri = _resolveUri(mediaPlaylistBaseUri!, trimmedLine);
          final HlsSegmentEntry? segmentEntry = segmentsToCache.firstWhereOrNull((s) => s.originalUrl == segmentOriginalUri.toString());

          if (segmentEntry != null && segmentEntry.isComplete) {
            // Point to local proxy URL for completed segments
            final String localProxySegmentUrl = _proxyServer.getHlsSegmentProxyUrl(trackId, segmentEntry.localRelativePath);
            finalMediaPlaylistContent += '$localProxySegmentUrl\n';
            AppLogger.info('Rewrote media playlist segment line: $trimmedLine to local proxy: $localProxySegmentUrl', name: 'HlsCacheHandler');
          } else {
            // Point to original URL for incomplete/missing segments
            finalMediaPlaylistContent += '$trimmedLine\n';
            AppLogger.info('Kept original media playlist segment line (incomplete/missing): $trimmedLine', name: 'HlsCacheHandler');
          }
        } else {
          finalMediaPlaylistContent += '$line\n'; // Keep other lines as is
        }
      }

      // Save the rewritten media playlist locally
      final File localMediaPlaylistFile = File(localMediaPlaylistPath);
      await localMediaPlaylistFile.writeAsString(finalMediaPlaylistContent);
      AppLogger.info('Rewritten HLS media playlist saved to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');


      // 6. Rewrite Master Manifest: to point to the local media playlist (which itself is rewritten)
      String finalMasterManifestContent = '';
      for (String line in masterManifestContent!.split('\n')) {
        String trimmedLine = line.trim();
        if (trimmedLine.startsWith('#EXT-X-STREAM-INF')) {
          finalMasterManifestContent += line + '\n'; // Keep the stream-info line
          int streamInfIndex = masterManifestContent.split('\n').indexOf(line);
          if (streamInfIndex + 1 < masterManifestContent.split('\n').length) {
            String uriLine = masterManifestContent.split('\n')[streamInfIndex + 1].trim();
            if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
              // Point to the local media playlist file
              finalMasterManifestContent += '$mediaPlaylistFileName\n'; // Use the local file name for the media playlist
              AppLogger.info('Rewrote master manifest media playlist line: $uriLine to local file: $mediaPlaylistFileName', name: 'HlsCacheHandler');
            }
          }
        } else {
          finalMasterManifestContent += line + '\n'; // Keep other lines as is
        }
      }

      // Save the rewritten master manifest locally
      final String localMasterManifestPath = p.join(hlsTrackDirPath, masterManifestFileName!);
      final File localMasterManifestFile = File(localMasterManifestPath);
      await localMasterManifestFile.writeAsString(finalMasterManifestContent);
      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      AppLogger.info('HLS caching process completed for track $trackId. Local master manifest: $localMasterManifestPath', name: 'HlsCacheHandler');
      return 'file://$localMasterManifestPath'; // Return file:// URL to the local master manifest

    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
      // On error, clean up the partial directory and metadata
      if (await hlsTrackDir.exists()) {
        AppLogger.info('Cleaning up partial HLS cache directory: ${hlsTrackDir.path}', name: 'HlsCacheHandler');
        await hlsTrackDir.delete(recursive: true);
      }
      await _metadataStore.delete(trackId); // Delete metadata for incomplete cache
      return null;
    }
  }

  /// Helper to resolve relative URIs against a base URI.
  Uri _resolveUri(Uri baseUri, String relativePath) {
    if (Uri.parse(relativePath).isAbsolute) {
      return Uri.parse(relativePath);
    }
    return baseUri.resolve(relativePath);
  }

  /// Helper to get the relative path of a segment within the HLS track directory.
  String _getRelativeSegmentPath(Uri mediaPlaylistBaseUri, Uri segmentUri) {
    // This is crucial for maintaining the directory structure within the cache.
    // It calculates the path of the segment relative to the media playlist's base directory.
    // Example: mediaPlaylistBaseUri = http://example.com/path/to/playlist.m3u8
    //          segmentUri = http://example.com/path/to/segments/segment1.ts
    // Result: segments/segment1.ts
    final String baseDir = mediaPlaylistBaseUri.path.substring(0, mediaPlaylistBaseUri.path.lastIndexOf('/') + 1);
    return p.relative(segmentUri.path, from: baseDir);
  }

  /// Deletes a cached HLS stream directory.
  Future<void> deleteCachedHls(String hlsLocalDirPath) async {
    final Directory hlsDir = Directory(hlsLocalDirPath);
    if (await hlsDir.exists()) {
      AppLogger.info('Deleting HLS cache directory: ${hlsDir.path}', name: 'HlsCacheHandler');
      await hlsDir.delete(recursive: true);
    }
  }
}

// Extension to easily find HlsSegmentEntry by originalUrl
extension on List<HlsSegmentEntry> {
  HlsSegmentEntry? firstWhereOrNull(bool Function(HlsSegmentEntry) test) {
    for (var element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}

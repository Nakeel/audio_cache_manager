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

import 'network_checker.dart';

class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);
  static const String _masterManifestFileName = 'master.m3u8';
  static const String _mediaPlaylistFileName = 'media.m3u8';

  final LocalProxyServer _proxyServer;
  final CacheMetadataStore _metadataStore;
  final InternetChecker _internetChecker;

  HlsCacheHandler({
    required LocalProxyServer proxyServer,
    required CacheMetadataStore metadataStore,
    required InternetChecker internetChecker,
  })  : _proxyServer = proxyServer,
        _metadataStore = metadataStore,
        _internetChecker = internetChecker;

  /// Caches an HLS stream, downloading a single chosen variant and its segments.
  /// It supports resuming incomplete downloads and stores segment-level metadata.
  /// It saves original manifests locally, and segments (potentially encrypted).
  /// Returns the local path to the base HLS directory.
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

    CacheEntry? existingEntry = await _metadataStore.get(trackId);
    List<HlsSegmentEntry> segmentsToCache = [];
    String? masterManifestContent;
    String? mediaPlaylistContent;
    Uri? mediaPlaylistBaseUri;

    try {
      if (!await hlsTrackDir.exists()) {
        await hlsTrackDir.create(recursive: true);
        AppLogger.info('Created HLS cache directory: ${hlsTrackDir.path}', name: 'HlsCacheHandler');
      }

      // 1. Download or load Master Manifest
      final File localMasterManifestFile = File(p.join(hlsTrackDirPath, _masterManifestFileName));
      if (await localMasterManifestFile.exists()) {
        masterManifestContent = await localMasterManifestFile.readAsString();
        AppLogger.info('Loaded existing master manifest for $trackId from ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
      }

      if (masterManifestContent == null) {
        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet to download master manifest for $trackId. Cannot proceed with caching.', name: 'HlsCacheHandler');
          return null;
        }
        AppLogger.info('Downloading master manifest from $hlsUrl', name: 'HlsCacheHandler');
        final http.Response masterManifestResponse = await http.get(hlsUri);
        if (masterManifestResponse.statusCode != 200) {
          AppLogger.error('Failed to download master manifest: ${masterManifestResponse.statusCode}', name: 'HlsCacheHandler');
          throw Exception('Failed to download master manifest');
        }
        masterManifestContent = masterManifestResponse.body;
        await localMasterManifestFile.writeAsString(masterManifestContent); // Save original master manifest
        AppLogger.info('Saved original master manifest to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
      }

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
      if (mediaPlaylistUrls.isNotEmpty) {
        selectedMediaPlaylistUrl = _resolveUri(baseUri, mediaPlaylistUrls.first).toString();
        AppLogger.info('Selected media playlist: $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
      } else {
        AppLogger.info('No EXT-X-STREAM-INF found, assuming single media playlist from original URL.', name: 'HlsCacheHandler');
        selectedMediaPlaylistUrl = hlsUrl;
      }


      // 2. Download or load Media Playlist (the chosen variant's playlist)
      final File localMediaPlaylistFile = File(p.join(hlsTrackDirPath, _mediaPlaylistFileName)); // Fixed name for media playlist
      if (await localMediaPlaylistFile.exists()) {
        mediaPlaylistContent = await localMediaPlaylistFile.readAsString();
        AppLogger.info('Loaded existing media playlist for $trackId from ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');
      }

      if (mediaPlaylistContent == null) {
        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet to download media playlist for $trackId. Cannot proceed with caching.', name: 'HlsCacheHandler');
          return null;
        }
        AppLogger.info('Downloading media playlist from $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
        final http.Response mediaPlaylistResponse = await http.get(Uri.parse(selectedMediaPlaylistUrl));
        if (mediaPlaylistResponse.statusCode != 200) {
          AppLogger.error('Failed to download media playlist: ${mediaPlaylistResponse.statusCode}', name: 'HlsCacheHandler');
          throw Exception('Failed to download media playlist');
        }
        mediaPlaylistContent = mediaPlaylistResponse.body;
        await localMediaPlaylistFile.writeAsString(mediaPlaylistContent); // Save original media playlist
        AppLogger.info('Saved original media playlist to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');
      }
      mediaPlaylistBaseUri = Uri.parse(selectedMediaPlaylistUrl);


      // 3. Prepare segments for download/resumption
      List<String> mediaPlaylistLines = mediaPlaylistContent.split('\n');
      List<String> allSegmentOriginalUrls = [];

      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#') && !trimmedLine.startsWith('#EXT')) {
          allSegmentOriginalUrls.add(_resolveUri(mediaPlaylistBaseUri, trimmedLine).toString());
        }
      }

      if (existingEntry != null && existingEntry.hlsSegments != null) {
        segmentsToCache = List.from(existingEntry.hlsSegments!);
        for (String originalUrl in allSegmentOriginalUrls) {
          if (!segmentsToCache.any((s) => s.originalUrl == originalUrl)) {
            final String relativeSegmentPath = _getRelativeSegmentPath(mediaPlaylistBaseUri, Uri.parse(originalUrl));
            segmentsToCache.add(HlsSegmentEntry(originalUrl: originalUrl, localRelativePath: relativeSegmentPath));
          }
        }
      } else {
        for (String originalUrl in allSegmentOriginalUrls) {
          final String relativeSegmentPath = _getRelativeSegmentPath(mediaPlaylistBaseUri, Uri.parse(originalUrl));
          segmentsToCache.add(HlsSegmentEntry(originalUrl: originalUrl, localRelativePath: relativeSegmentPath));
        }
      }

      int totalSegments = segmentsToCache.length;
      int downloadedSegmentsCount = segmentsToCache.where((s) => s.isComplete).length;
      int currentTotalBytes = segmentsToCache.where((s) => s.isComplete).fold(0, (sum, s) => sum + s.totalBytes);

      if (onProgress != null) {
        onProgress(downloadedSegmentsCount, totalSegments);
      }

      // 4. Download/Resume Segments sequentially
      for (int i = 0; i < segmentsToCache.length; i++) {
        HlsSegmentEntry segment = segmentsToCache[i];

        if (segment.isComplete) {
          AppLogger.info('Segment ${segment.localRelativePath} already complete. Skipping download.', name: 'HlsCacheHandler');
          continue;
        }

        if (!await _internetChecker.hasInternet) {
          AppLogger.warning('No internet connection. Halting HLS segment download for track $trackId. Will continue with hybrid playback.', name: 'HlsCacheHandler');
          break;
        }

        AppLogger.info('Processing segment: ${segment.originalUrl}', name: 'HlsCacheHandler');
        final Uri segmentUri = Uri.parse(segment.originalUrl);
        final File segmentFile = File(p.join(hlsTrackDirPath, segment.localRelativePath));

        if (!await segmentFile.parent.exists()) {
          await segmentFile.parent.create(recursive: true);
        }

        bool segmentDownloadSuccess = false;
        for (int retry = 0; retry < _maxSegmentRetries; retry++) {
          if (!await _internetChecker.hasInternet) {
            AppLogger.warning('No internet connection during retry for segment ${segment.localRelativePath}. Halting HLS segment download.', name: 'HlsCacheHandler');
            break;
          }

          try {
            int startByte = 0;
            if (await segmentFile.exists()) {
              startByte = await segmentFile.length();
              if (startByte > 0 && startByte < segment.totalBytes) {
                AppLogger.info('Resuming download for segment ${segment.localRelativePath} from byte $startByte', name: 'HlsCacheHandler');
              } else if (startByte == segment.totalBytes && segment.totalBytes > 0) {
                // If file exists and matches expected total bytes, mark as complete and skip
                // We'll calculate hash only if we actually download/write
                segment = segment.copyWith(isComplete: true, downloadedBytes: startByte);
                segmentsToCache[i] = segment;
                segmentDownloadSuccess = true;
                AppLogger.info('Segment ${segment.localRelativePath} already fully downloaded. Skipping.', name: 'HlsCacheHandler');
                break;
              } else if (startByte > 0 && segment.totalBytes == 0) {
                AppLogger.info('Segment ${segment.localRelativePath} exists with $startByte bytes, but total unknown. Attempting resume.', name: 'HlsCacheHandler');
              }
            }

            final Map<String, String> headers = {};
            if (startByte > 0) {
              headers['Range'] = 'bytes=$startByte-';
            }

            final http.Response segmentResponse = await http.get(segmentUri, headers: headers);

            if (segmentResponse.statusCode == 200 || segmentResponse.statusCode == 206) {
              Uint8List segmentBytes = segmentResponse.bodyBytes;
              int newDownloadedBytes = startByte + segmentBytes.length;
              int segmentTotalBytes = segmentResponse.contentLength ?? 0;

              if (segmentResponse.statusCode == 200 && startByte > 0) {
                AppLogger.warning('Server did not support Range requests for ${segment.localRelativePath}. Re-downloading from start.', name: 'HlsCacheHandler');
                await segmentFile.delete();
                startByte = 0;
                newDownloadedBytes = segmentBytes.length;
              }

              // Calculate hash of the original (decrypted) content BEFORE encryption
              String? segmentDataHash = AESHelper.calculateSha256(segmentBytes);
              AppLogger.info('Calculated SHA-256 hash for segment ${segment.localRelativePath}: $segmentDataHash', name: 'HlsCacheHandler');


              if (encrypt) {
                AppLogger.info('Encrypting HLS segment: ${segmentFile.path} for track $trackId', name: 'HlsCacheHandler');
                segmentBytes = AESHelper.encrypt(segmentBytes);
              }

              if (startByte > 0 && segmentResponse.statusCode == 206) {
                await segmentFile.writeAsBytes(segmentBytes, mode: FileMode.append);
              } else {
                await segmentFile.writeAsBytes(segmentBytes);
              }

              segment = segment.copyWith(
                downloadedBytes: newDownloadedBytes,
                totalBytes: segmentTotalBytes > 0 ? segmentTotalBytes : newDownloadedBytes,
                isComplete: (segmentTotalBytes > 0 && newDownloadedBytes >= segmentTotalBytes) || (segmentTotalBytes == 0 && newDownloadedBytes > 0),
                dataHash: segmentDataHash, // NEW: Store the hash
              );
              segmentsToCache[i] = segment;
              AppLogger.info('Saved segment: ${segment.localRelativePath}, downloaded: ${segment.downloadedBytes}/${segment.totalBytes} bytes, complete: ${segment.isComplete}', name: 'HlsCacheHandler');
              segmentDownloadSuccess = true;

              currentTotalBytes += segmentBytes.length;

              break;
            } else {
              AppLogger.warning('Failed to download segment ${segment.localRelativePath}: ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
            }
          } on SocketException catch (e, st) {
            AppLogger.warning('SocketException during segment download for ${segment.localRelativePath}: $e. This often indicates network loss. Halting download.', name: 'HlsCacheHandler');
            segmentDownloadSuccess = false;
            break;
          } catch (e, st) {
            AppLogger.error('Error downloading segment ${segment.localRelativePath}: $e. Retrying...', error: e, stackTrace: st, name: 'HlsCacheHandler');
          }
          await Future.delayed(_retryDelay);
        }

        if (!segmentDownloadSuccess) {
          AppLogger.error('Failed to download segment after $_maxSegmentRetries retries or network lost: ${segment.originalUrl}', name: 'HlsCacheHandler');
          segment = segment.copyWith(isComplete: false, dataHash: null); // Clear hash if incomplete
          segmentsToCache[i] = segment;
          if (!await _internetChecker.hasInternet) {
            AppLogger.warning('Network still unavailable after segment failure. Stopping further HLS segment downloads.', name: 'HlsCacheHandler');
            break;
          }
        }

        downloadedSegmentsCount = segmentsToCache.where((s) => s.isComplete).length;
        if (onProgress != null) {
          onProgress(downloadedSegmentsCount, totalSegments);
        }

        // Save metadata after each segment to ensure progress is persisted
        await _metadataStore.save(
          existingEntry?.copyWith(
            hlsSegments: segmentsToCache,
            fileSize: currentTotalBytes,
          ) ?? CacheEntry(
            trackId: trackId,
            originalUrl: hlsUrl,
            filePath: '',
            timestamp: DateTime.now(),
            fileSize: currentTotalBytes,
            isEncrypted: encrypt,
            etag: '',
            lastModified: '',
            contentType: 'application/x-mpegURL',
            proxyUrl: _proxyServer.getProxyUrl(trackId),
            isHls: true,
            hlsLocalPath: hlsTrackDirPath,
            hlsSegments: segmentsToCache,
            dataHash: null, // Master entry doesn't have a single dataHash
          ),
        );
      } // End of segment download loop

      AppLogger.info('HLS caching process completed for track $trackId. Local HLS directory: $hlsTrackDirPath', name: 'HlsCacheHandler');
      return hlsTrackDirPath;
    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
      if (await hlsTrackDir.exists()) {
        AppLogger.info('Cleaning up partial HLS cache directory: ${hlsTrackDir.path}', name: 'HlsCacheHandler');
        await hlsTrackDir.delete(recursive: true);
      }
      await _metadataStore.delete(trackId);
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

import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';

class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  final LocalProxyServer _proxyServer; // Add this line

  // Modify the constructor to accept LocalProxyServer
  HlsCacheHandler({required LocalProxyServer proxyServer}) : _proxyServer = proxyServer;

  /// Caches an HLS stream, downloading a single chosen variant and its segments sequentially.
  /// Returns the local path to the rewritten master manifest.
  ///
  /// By default, it attempts to select the smallest bandwidth video variant
  /// and its associated audio track.
  Future<String?> cacheHls(
      String hlsUrl,
      String cacheBaseDirPath,
      String trackId, {
        Function(int received, int total)? onProgress,
        bool encrypt = false, // Add encrypt parameter here
      }) async {
    AppLogger.info('Attempting to cache SINGLE HLS variant sequentially: $hlsUrl for track $trackId', name: 'HlsCacheHandler');

    final Uri hlsUri = Uri.parse(hlsUrl);
    final String hlsCacheDirPath = p.join(cacheBaseDirPath, trackId);
    final Directory hlsCacheDir = Directory(hlsCacheDirPath);

    try {
      if (!await hlsCacheDir.exists()) {
        await hlsCacheDir.create(recursive: true);
        AppLogger.info('Created HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
      }

      // 1. Download Master Manifest
      AppLogger.info('Downloading master manifest from $hlsUrl', name: 'HlsCacheHandler');
      final http.Response masterManifestResponse = await http.get(hlsUri);
      if (masterManifestResponse.statusCode != 200) {
        AppLogger.error('Failed to download master manifest: ${masterManifestResponse.statusCode}', name: 'HlsCacheHandler');
        throw Exception('Failed to download master manifest');
      }

      String masterManifestContent = masterManifestResponse.body;
      Uri baseUri = hlsUri; // Base URI for resolving relative paths in manifest

      // Parse master manifest to find variants
      List<String> mediaPlaylistUrls = [];
      List<String> lines = masterManifestContent.split('\n');
      for (int i = 0; i < lines.length; i++) {
        String line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          // This line describes a variant stream
          // Find the URI on the next line
          if (i + 1 < lines.length) {
            String uriLine = lines[i + 1].trim();
            if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
              mediaPlaylistUrls.add(uriLine);
            }
          }
        }
      }

      if (mediaPlaylistUrls.isEmpty) {
        // If no stream-inf found, assume it's a media playlist directly (single variant)
        AppLogger.info('No EXT-X-STREAM-INF found, assuming single media playlist.', name: 'HlsCacheHandler');
        mediaPlaylistUrls.add(hlsUrl); // Treat the original URL as the media playlist
      }

      String? selectedMediaPlaylistUrl;
      // For simplicity, select the first media playlist found
      if (mediaPlaylistUrls.isNotEmpty) {
        selectedMediaPlaylistUrl = _resolveUri(baseUri, mediaPlaylistUrls.first).toString();
        AppLogger.info('Selected media playlist: $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
      } else {
        AppLogger.error('No media playlists found in master manifest.', name: 'HlsCacheHandler');
        throw Exception('No media playlists found');
      }

      // 2. Download Media Playlist (the chosen variant's playlist)
      AppLogger.info('Downloading media playlist from $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
      final http.Response mediaPlaylistResponse = await http.get(Uri.parse(selectedMediaPlaylistUrl));
      if (mediaPlaylistResponse.statusCode != 200) {
        AppLogger.error('Failed to download media playlist: ${mediaPlaylistResponse.statusCode}', name: 'HlsCacheHandler');
        throw Exception('Failed to download media playlist');
      }

      String mediaPlaylistContent = mediaPlaylistResponse.body;
      Uri mediaPlaylistBaseUri = Uri.parse(selectedMediaPlaylistUrl); // Base URI for resolving segments

      // 3. Download Segments sequentially and rewrite media playlist
      List<String> segmentUrls = [];
      String rewrittenMediaPlaylistContent = '';
      int totalSegments = 0;
      int downloadedSegments = 0;

      List<String> mediaPlaylistLines = mediaPlaylistContent.split('\n');
      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          // This is a segment URI
          segmentUrls.add(_resolveUri(mediaPlaylistBaseUri, trimmedLine).toString());
          totalSegments++;
        }
      }

      // Track progress for segments
      int currentProgress = 0;
      int segmentTotalBytes = 0; // Total bytes for all segments (if known)
      if (onProgress != null) {
        // We can't know total bytes for all segments upfront,
        // so we'll report progress based on segment count
        segmentTotalBytes = totalSegments;
      }


      for (String segmentUrl in segmentUrls) {
        AppLogger.info('Downloading segment: $segmentUrl', name: 'HlsCacheHandler');
        final Uri segmentUri = Uri.parse(segmentUrl);
        final String segmentFileName = p.basename(segmentUri.path);
        final File segmentFile = File(p.join(hlsCacheDirPath, segmentFileName));

        bool segmentDownloaded = false;
        for (int retry = 0; retry < _maxSegmentRetries; retry++) {
          try {
            final http.Response segmentResponse = await http.get(segmentUri);
            if (segmentResponse.statusCode == 200) {
              Uint8List segmentBytes = segmentResponse.bodyBytes;

              if (encrypt) {
                AppLogger.info('Encrypting HLS segment: $segmentFileName for track $trackId', name: 'HlsCacheHandler');
                segmentBytes = AESHelper.encrypt(segmentBytes); // Encrypt segment bytes
              }

              await segmentFile.writeAsBytes(segmentBytes);
              AppLogger.info('Saved segment: ${segmentFile.path}', name: 'HlsCacheHandler');
              segmentDownloaded = true;
              break; // Segment downloaded successfully
            } else {
              AppLogger.warning('Failed to download segment ${segmentFile.path}: ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
            }
          } catch (e, st) {
            AppLogger.error('Error downloading segment ${segmentFile.path}: $e. Retrying...', error: e, stackTrace: st, name: 'HlsCacheHandler');
          }
          await Future.delayed(_retryDelay);
        }

        if (!segmentDownloaded) {
          AppLogger.error('Failed to download segment after $_maxSegmentRetries retries: $segmentUrl', name: 'HlsCacheHandler');
          throw Exception('Failed to download segment: $segmentUrl');
        }

        // Increment progress for each successful segment download
        downloadedSegments++;
        if (onProgress != null) {
          onProgress(downloadedSegments, totalSegments);
        }
      }

      // Rewrite manifest to point to proxy URLs
      String rewrittenMasterManifestContent = masterManifestContent;

      // HLS Master manifest usually contains variants which are media playlists
      // We need to rewrite these media playlist URLs to point to the proxy
      for (int i = 0; i < lines.length; i++) {
        String line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          if (i + 1 < lines.length) {
            String uriLine = lines[i + 1].trim();
            if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
              // Construct proxy URL for the media playlist
              final String mediaPlaylistFileName = p.basename(Uri.parse(uriLine).path);
              final String proxyMediaPlaylistUrl = _proxyServer.getHlsManifestProxyUrl(trackId, mediaPlaylistFileName);

              // Replace the original URI with the proxy URI in the content
              rewrittenMasterManifestContent = rewrittenMasterManifestContent.replaceAll(uriLine, proxyMediaPlaylistUrl);
              AppLogger.info('Rewrote master manifest line: $uriLine to $proxyMediaPlaylistUrl', name: 'HlsCacheHandler');
            }
          }
        }
      }


      // Rewrite Media Playlist (segments) to point to proxy URLs
      String finalMediaPlaylistContent = '';
      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          // This is a segment URI, replace with proxy URL
          final Uri segmentUri = _resolveUri(mediaPlaylistBaseUri, trimmedLine);
          final String segmentFileName = p.basename(segmentUri.path); // Get just the filename
          final String proxySegmentUrl = 'http://${_proxyServer.host}:${_proxyServer.port}/hls_segments/$trackId/$segmentFileName'; // Construct proxy URL for segment
          finalMediaPlaylistContent += '$proxySegmentUrl\n';
          AppLogger.info('Rewrote segment line: $trimmedLine to $proxySegmentUrl', name: 'HlsCacheHandler');
        } else {
          finalMediaPlaylistContent += '$line\n'; // Keep other lines as is
        }
      }

      // Save the rewritten media playlist locally
      final String localMediaPlaylistFileName = p.basename(Uri.parse(selectedMediaPlaylistUrl).path);
      final File localMediaPlaylistFile = File(p.join(hlsCacheDirPath, localMediaPlaylistFileName));
      await localMediaPlaylistFile.writeAsString(finalMediaPlaylistContent);
      AppLogger.info('Rewritten HLS media playlist saved to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');

      // Save the rewritten master manifest locally
      final String localMasterManifestFileName = p.basename(hlsUri.path);
      final File localMasterManifestFile = File(p.join(hlsCacheDirPath, localMasterManifestFileName));
      await localMasterManifestFile.writeAsString(rewrittenMasterManifestContent);
      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      AppLogger.info('HLS caching complete for track $trackId. Local manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
      // Return the local path to the rewritten master manifest file
      return localMasterManifestFile.path;

    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
      if (await hlsCacheDir.exists()) {
        AppLogger.info('Cleaning up partial HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
        await hlsCacheDir.delete(recursive: true);
      }
      return null;
    }
  }

  /// Helper to resolve relative URIs against a base URI.
  Uri _resolveUri(Uri baseUri, String relativePath) {
    if (Uri.parse(relativePath).isAbsolute) {
      return Uri.parse(relativePath);
    }
    return baseUri.resolve(relativePath); // Use resolve for better URI handling
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
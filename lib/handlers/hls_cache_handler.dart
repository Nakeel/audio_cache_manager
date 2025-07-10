// lib/data/services/hls_cache_handler.dart

import 'dart:io';
import 'dart:convert';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

class HlsCacheHandler {
  final Dio _dio = Dio();

  /// Caches an HLS stream by downloading its manifest and all segments.
  /// Returns the local path to the rewritten manifest.
  Future<String?> cacheHls(
      String remoteUrl,
      String cacheBaseDirPath,
      String trackId, // Use trackId for deterministic naming
          {
        Function(int received, int total)? onProgress,
      }) async
  {
    AppLogger.info('Attempting to cache HLS: $remoteUrl for track $trackId');

    final Uri remoteUri = Uri.parse(remoteUrl);
    final String baseUrl = remoteUri.scheme.isEmpty
        ? remoteUrl.substring(0, remoteUrl.lastIndexOf('/') + 1)
        : remoteUri.resolve('.').toString(); // Base URL for resolving relative paths

    // Create a unique directory for this HLS stream's segments and manifest
    // This makes cleanup easier and prevents name clashes for segments
    final String hlsCacheDirName = trackId.replaceAll(RegExp(r'[^\w\s.-]'), '_'); // Sanitize
    final String hlsLocalDirPath = p.join(cacheBaseDirPath, hlsCacheDirName);
    final Directory hlsDir = Directory(hlsLocalDirPath);

    if (!await hlsDir.exists()) {
      await hlsDir.create(recursive: true);
      AppLogger.info('Created HLS cache directory: $hlsLocalDirPath');
    }

    final String localManifestFileName = 'playlist.m3u8';
    final String localManifestPath = p.join(hlsLocalDirPath, localManifestFileName);

    try {
      // 1. Download the primary HLS manifest
      AppLogger.info('Downloading HLS manifest from $remoteUrl');
      final Response<String> manifestResponse = await _dio.get(
        remoteUrl,
        options: Options(responseType: ResponseType.plain),
      );

      String manifestContent = manifestResponse.data!;
      List<String> lines = LineSplitter.split(manifestContent).toList();
      List<String> rewrittenLines = [];
      List<String> segmentUrlsToDownload = [];

      // Simple total for progress for this specific HLS stream
      int totalSegments = 0;
      int downloadedSegments = 0;

      // First pass: Count segments and identify actual segment lines
      for (String line in lines) {
        if (line.endsWith('.ts')) { // Check for segment files (can be .mp4, etc. too)
          totalSegments++;
        }
      }

      AppLogger.info('Found $totalSegments segments in manifest. Starting download...');

      // 2. Parse manifest, download segments, and rewrite paths
      for (String line in lines) {
        if (line.startsWith('#EXTINF:') || line.startsWith('#EXT-X-BYTERANGE:') || line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
          // Keep these lines as is (EXTINF for duration, BYTERANGE, etc.)
          rewrittenLines.add(line);
        } else if (line.endsWith('.ts') || line.endsWith('.mp4') || line.endsWith('.aac') || line.endsWith('.vtt')) {
          // This is likely a media segment or subtitle file
          Uri segmentUri = remoteUri.resolve(line); // Resolve relative path
          String segmentFileName = p.basename(segmentUri.path);
          String localSegmentPath = p.join(hlsLocalDirPath, segmentFileName);

          // Add to download list and rewrite manifest line
          segmentUrlsToDownload.add(segmentUri.toString());
          rewrittenLines.add(segmentFileName); // Replace remote URL with local filename
        } else if (line.startsWith('#')) {
          // Keep other HLS tags (e.g., #EXT-X-VERSION, #EXT-X-TARGETDURATION)
          rewrittenLines.add(line);
        } else if (line.trim().isEmpty) {
          // Keep empty lines
          rewrittenLines.add(line);
        } else {
          // If it's not a tag, and not a segment, it might be a sub-playlist.
          // For simplicity in Phase 3 initial, we're not handling nested playlists.
          // If you encounter them, you'd need recursive parsing.
          AppLogger.warning('Skipping unrecognized HLS manifest line: $line');
        }
      }

      // 3. Download all identified segments sequentially for easier progress tracking
      // For very large HLS, consider concurrent downloads (Future.wait) with throttling.
      for (String segmentUrl in segmentUrlsToDownload) {
        final Uri segmentUri = Uri.parse(segmentUrl);
        final String segmentFileName = p.basename(segmentUri.path);
        final String localSegmentPath = p.join(hlsLocalDirPath, segmentFileName);

        File segmentFile = File(localSegmentPath);
        if (await segmentFile.exists()) {
          AppLogger.info('Segment $segmentFileName already exists locally. Skipping download.');
          downloadedSegments++;
          if (onProgress != null) {
            onProgress(downloadedSegments, totalSegments);
          }
          continue;
        }

        try {
          AppLogger.info('Downloading segment: $segmentUrl to $localSegmentPath');
          await _dio.download(
            segmentUrl,
            localSegmentPath,
            onReceiveProgress: (received, total) {
              // This progress is per segment.
              // You might want to aggregate this for overall progress.
            },
          );
          downloadedSegments++;
          if (onProgress != null) {
            // Report overall progress for HLS
            onProgress(downloadedSegments, totalSegments);
          }
        } catch (e, st) {
          AppLogger.error('Failed to download HLS segment $segmentUrl: $e', error: e, stackTrace: st);
          // Decide if you want to abort or continue on segment failure
          // For now, we'll continue but log the error
        }
      }

      // 4. Save the rewritten manifest locally
      final File localManifestFile = File(localManifestPath);
      await localManifestFile.writeAsString(rewrittenLines.join('\n'));
      AppLogger.info('Rewritten HLS manifest saved to: $localManifestPath');

      AppLogger.info('HLS caching complete for track $trackId. Local manifest: $localManifestPath');
      return localManifestPath; // Return the path to the local manifest
    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $remoteUrl: $e', error: e, stackTrace: st);
      // Clean up the partial directory if caching failed
      if (await hlsDir.exists()) {
        await hlsDir.delete(recursive: true);
        AppLogger.warning('Cleaned up partial HLS cache directory: $hlsLocalDirPath');
      }
      return null;
    }
  }

  /// Deletes all files associated with a cached HLS stream.
  Future<void> deleteCachedHls(String hlsLocalDirPath) async {
    final Directory hlsDir = Directory(hlsLocalDirPath);
    if (await hlsDir.exists()) {
      try {
        await hlsDir.delete(recursive: true);
        AppLogger.info('Deleted HLS cache directory: $hlsLocalDirPath');
      } catch (e, st) {
        AppLogger.error('Failed to delete HLS cache directory $hlsLocalDirPath: $e', error: e, stackTrace: st);
      }
    }
  }
}
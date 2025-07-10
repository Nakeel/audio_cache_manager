// lib/data/services/hls_cache_handler.dart

import 'dart:io';
import 'dart:convert';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart';
import 'package:http/http.dart' as http show Response, get;
import 'package:path/path.dart' as p;


class HlsCacheHandler {
  /// Caches an HLS stream, downloading a selected variant and its segments.
  /// Returns the local path to the rewritten master manifest.
  Future<String?> cacheHls(
      String hlsUrl,
      String cacheBaseDirPath,
      String trackId, {
        Function(int received, int total)? onProgress,
      }) async {
    AppLogger.info('Attempting to cache HLS: $hlsUrl for track $trackId', name: 'HlsCacheHandler');

    final Uri hlsUri = Uri.parse(hlsUrl);
    final String hlsCacheDirPath = p.join(cacheBaseDirPath, trackId);
    final Directory hlsCacheDir = Directory(hlsCacheDirPath);

    try {
      if (!await hlsCacheDir.exists()) {
        await hlsCacheDir.create(recursive: true);
        AppLogger.info('Created HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
      }

      // 1. Download Master Manifest
      AppLogger.info('Downloading HLS manifest from $hlsUrl', name: 'HlsCacheHandler');
      final http.Response masterManifestResponse = await http.get(hlsUri);
      if (masterManifestResponse.statusCode != 200) {
        throw Exception('Failed to download HLS master manifest: ${masterManifestResponse.statusCode}');
      }

      final String masterManifestContent = masterManifestResponse.body;
      final List<String> masterManifestLines = masterManifestContent.split('\n');

      // 2. Parse Master Manifest for Variant Playlists and Select One
      String? selectedVariantPlaylistUrl;
      // Regex to find EXT-X-STREAM-INF followed by a URI on the next line
      final RegExp streamInfPattern = RegExp(r'^#EXT-X-STREAM-INF.*', multiLine: true);


      for (int i = 0; i < masterManifestLines.length; i++) {
        final String currentLine = masterManifestLines[i].trim();
        if (streamInfPattern.hasMatch(currentLine)) {
          // If the next line exists and is not a comment and ends with .m3u8, it's a variant playlist
          if (i + 1 < masterManifestLines.length) {
            final String nextLine = masterManifestLines[i + 1].trim();
            if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
              selectedVariantPlaylistUrl = _resolveUri(hlsUri, nextLine).toString();
              AppLogger.info('Found variant playlist: $selectedVariantPlaylistUrl', name: 'HlsCacheHandler');
              break; // For simplicity, pick the first one found
            }
          }
        } else if (!currentLine.startsWith('#') && currentLine.endsWith('.m3u8') && selectedVariantPlaylistUrl == null) {
          // Fallback: If master manifest directly lists .m3u8 files without EXT-X-STREAM-INF
          selectedVariantPlaylistUrl = _resolveUri(hlsUri, currentLine).toString();
          AppLogger.info('Found direct variant playlist (no EXT-X-STREAM-INF): $selectedVariantPlaylistUrl', name: 'HlsCacheHandler');
          break;
        }
      }

      if (selectedVariantPlaylistUrl == null) {
        AppLogger.warning('No explicit variant HLS playlist found in master manifest. Attempting to treat master as direct segment list.', name: 'HlsCacheHandler');
        selectedVariantPlaylistUrl = hlsUrl; // Fallback to original URL
      }


      // 3. Download Selected Variant Playlist
      AppLogger.info('Downloading selected variant playlist from $selectedVariantPlaylistUrl', name: 'HlsCacheHandler');
      final Uri variantUri = Uri.parse(selectedVariantPlaylistUrl);
      final http.Response variantManifestResponse = await http.get(variantUri);
      if (variantManifestResponse.statusCode != 200) {
        throw Exception('Failed to download HLS variant manifest: ${variantManifestResponse.statusCode}');
      }

      final String variantManifestContent = variantManifestResponse.body;
      final List<String> variantManifestLines = variantManifestContent.split('\n');

      // 4. Parse Variant Playlist for Media Segments and Download
      final List<String> localSegmentPaths = [];
      final List<String> rewrittenVariantLines = [];
      int totalSegments = 0;
      int downloadedSegments = 0;

      for (final line in variantManifestLines) {
        final trimmedLine = line.trim(); // Always trim the line

        rewrittenVariantLines.add(line); // Add original line, will be overwritten if it's a segment

        // Robust segment detection:
        // - Not a comment/directive line
        // - Ends with a common media segment extension (.ts, .mp4)
        // - Does NOT contain '.m3u8' (to avoid confusing with nested playlists)
        if (!trimmedLine.startsWith('#') &&
            (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.mp4')) &&
            !trimmedLine.contains('.m3u8')) {

          // Add a very specific log here to confirm entry
          AppLogger.info('HLS Segment detection SUCCESS for: "$trimmedLine"', name: 'HlsCacheHandler');

          totalSegments++;
          final Uri segmentUri = _resolveUri(variantUri, trimmedLine);
          final String segmentFileName = p.basename(segmentUri.path);
          final String localSegmentPath = p.join(hlsCacheDirPath, segmentFileName);

          // Update the last added line in rewrittenVariantLines to point to the local file name
          // This relies on `rewrittenVariantLines.add(line)` being the previous action
          if (rewrittenVariantLines.isNotEmpty) {
            rewrittenVariantLines[rewrittenVariantLines.length - 1] = segmentFileName;
          }


          // Download segment
          try {
            AppLogger.info('Downloading segment: $segmentUri', name: 'HlsCacheHandler');
            final http.Response segmentResponse = await http.get(segmentUri);
            if (segmentResponse.statusCode == 200) {
              final File segmentFile = File(localSegmentPath);
              await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
              localSegmentPaths.add(localSegmentPath); // Keep track of downloaded segments
              downloadedSegments++;
              onProgress?.call(downloadedSegments, totalSegments);
              AppLogger.info('Downloaded segment to: $localSegmentPath', name: 'HlsCacheHandler');
            } else {
              AppLogger.warning('Failed to download segment $segmentUri: ${segmentResponse.statusCode}', name: 'HlsCacheHandler');
            }
          } catch (e, st) {
            AppLogger.error('Error downloading segment $segmentUri: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
          }
        } else {
          // This line is not a segment, or it's a directive, or it's another playlist.
          AppLogger.info('HLS Manifest Line (ignored for segment download logic): "$trimmedLine"', name: 'HlsCacheHandler');
        }
      }

      AppLogger.info('Found $totalSegments segments in manifest. Downloaded $downloadedSegments.', name: 'HlsCacheHandler');

      // 5. Rewrite Local Variant Manifest
      final String localVariantManifestFileName = p.basename(variantUri.path);
      final String localVariantManifestPath = p.join(hlsCacheDirPath, localVariantManifestFileName);
      final File localVariantManifestFile = File(localVariantManifestPath);
      await localVariantManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
      AppLogger.info('Rewritten local variant manifest saved to: ${localVariantManifestFile.path}', name: 'HlsCacheHandler');

      // 6. Rewrite Local Master Manifest to point to the local variant manifest
      final String localMasterManifestFileName = p.basename(hlsUri.path);
      final String localMasterManifestPath = p.join(hlsCacheDirPath, localMasterManifestFileName);
      final File localMasterManifestFile = File(localMasterManifestPath);

      final List<String> rewrittenMasterLines = [];
      bool variantLinked = false;
      for (int i = 0; i < masterManifestLines.length; i++) {
        final String currentLine = masterManifestLines[i].trim();
        rewrittenMasterLines.add(masterManifestLines[i]); // Add original line

        // Look for EXT-X-STREAM-INF and the subsequent URI
        if (streamInfPattern.hasMatch(currentLine) && !variantLinked) {
          if (i + 1 < masterManifestLines.length) {
            final String nextLine = masterManifestLines[i + 1].trim();
            if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
              // Replace the remote variant URI with the local variant manifest filename
              rewrittenMasterLines[rewrittenMasterLines.length - 1] = localVariantManifestFileName;
              variantLinked = true;
            }
          }
        } else if (!currentLine.startsWith('#') && currentLine.endsWith('.m3u8') && !variantLinked) {
          // Handle direct variant list without #EXT-X-STREAM-INF
          rewrittenMasterLines[rewrittenMasterLines.length - 1] = localVariantManifestFileName;
          variantLinked = true;
        }
      }

      // If no variant was linked (e.g., master manifest was itself the segment list),
      // ensure the local master manifest is effectively the rewritten variant manifest.
      if (!variantLinked && selectedVariantPlaylistUrl == hlsUrl) {
        await localMasterManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
      } else {
        await localMasterManifestFile.writeAsString(rewrittenMasterLines.join('\n'));
      }


      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      // Return the path to the local master manifest as the entry point for playback
      AppLogger.info('HLS caching complete for track $trackId. Local manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
      return localMasterManifestFile.path;

    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
      // Clean up partial downloads if an error occurs
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
    // Handle cases where the base path might not end with a '/'
    // e.g., base: 'http://example.com/path/playlist.m3u8', relative: 'segment.ts'
    // should resolve to 'http://example.com/path/segment.ts'
    // p.join handles trailing slashes correctly.
    final String resolvedPath = p.join(p.dirname(baseUri.path), relativePath);
    return baseUri.replace(path: resolvedPath);
  }

  /// Deletes a cached HLS stream directory.
  Future<void> deleteCachedHls(String hlsLocalDirPath) async {
    final Directory hlsDir = Directory(hlsLocalDirPath);
    if (await hlsDir.exists()) {
      AppLogger.info('Deleting HLS cache directory: ${hlsDir.path}', name: 'HlsCacheHandler');
      await hlsDir.delete(recursive: true);
    } else {
      AppLogger.info('HLS cache directory not found for deletion: $hlsLocalDirPath', name: 'HlsCacheHandler');
    }
  }
}
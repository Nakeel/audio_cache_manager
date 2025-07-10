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
      final RegExp streamInfRegex = RegExp(r'^#EXT-X-STREAM-INF.*,RESOLUTION=(\d+x\d+).*\n(.*\.m3u8)$', multiLine: true);
      // Fallback regex in case RESOLUTION is not present or structured differently
      final RegExp genericVariantRegex = RegExp(r'^(?!#).*(\.m3u8)$', multiLine: true); // Matches lines not starting with # and ending in .m3u8


      for (final line in masterManifestLines) {
        // Look for #EXT-X-STREAM-INF lines followed by a .m3u8 URI
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          // The actual URI is on the next line or after a newline
          final int index = masterManifestLines.indexOf(line);
          if (index + 1 < masterManifestLines.length) {
            final String nextLine = masterManifestLines[index + 1].trim();
            if (nextLine.endsWith('.m3u8') && !nextLine.startsWith('#')) {
              selectedVariantPlaylistUrl = _resolveUri(hlsUri, nextLine).toString();
              AppLogger.info('Found variant playlist: $selectedVariantPlaylistUrl', name: 'HlsCacheHandler');
              break; // For simplicity, pick the first one found
            }
          }
        } else if (line.endsWith('.m3u8') && !line.startsWith('#') && selectedVariantPlaylistUrl == null) {
          // Handle cases where variant playlists are just listed directly, without EXT-X-STREAM-INF preceding them directly
          selectedVariantPlaylistUrl = _resolveUri(hlsUri, line.trim()).toString();
          AppLogger.info('Found direct variant playlist: $selectedVariantPlaylistUrl (No EXT-X-STREAM-INF)', name: 'HlsCacheHandler');
          break; // For simplicity, pick the first one found
        }
      }

      if (selectedVariantPlaylistUrl == null) {
        AppLogger.warning('No variant HLS playlist found in master manifest. Attempting to treat master as direct segment list.', name: 'HlsCacheHandler');
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
        rewrittenVariantLines.add(line); // Add all lines to rewritten initially

        // Check if the line is a media segment (usually ends with .ts or .mp4, and not a directive)
        // Simplified check: not a #EXT line and ends with a common media extension
        if (!line.startsWith('#') && (line.endsWith('.ts') || line.endsWith('.mp4'))) {
          totalSegments++;
          final Uri segmentUri = _resolveUri(variantUri, line.trim());
          final String segmentFileName = p.basename(segmentUri.path);
          final String localSegmentPath = p.join(hlsCacheDirPath, segmentFileName);

          rewrittenVariantLines[rewrittenVariantLines.length - 1] = segmentFileName; // Rewrite to local path

          // Download segment
          try {
            AppLogger.info('Downloading segment: $segmentUri', name: 'HlsCacheHandler');
            final http.Response segmentResponse = await http.get(segmentUri);
            if (segmentResponse.statusCode == 200) {
              final File segmentFile = File(localSegmentPath);
              await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
              localSegmentPaths.add(localSegmentPath);
              downloadedSegments++;
              onProgress?.call(downloadedSegments, totalSegments);
              AppLogger.info('Downloaded segment to: $localSegmentPath', name: 'HlsCacheHandler');
            } else {
              AppLogger.warning('Failed to download segment $segmentUri: ${segmentResponse.statusCode}', name: 'HlsCacheHandler');
              // Continue processing other segments, but this one will be missing
            }
          } catch (e, st) {
            AppLogger.error('Error downloading segment $segmentUri: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
            // Continue processing other segments
          }
        } else {
          // If it's a #EXTINF line, ensure it's still included but not parsed as a segment itself
          AppLogger.info('HLS Manifest Line (ignored for segment download): $line', name: 'HlsCacheHandler');
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
      for (final line in masterManifestLines) {
        rewrittenMasterLines.add(line);
        if (line.startsWith('#EXT-X-STREAM-INF') && !variantLinked) {
          final int index = masterManifestLines.indexOf(line);
          if (index + 1 < masterManifestLines.length) {
            final String nextLine = masterManifestLines[index + 1].trim();
            if (nextLine.endsWith('.m3u8') && !nextLine.startsWith('#')) {
              // Replace the remote variant URI with the local variant manifest filename
              rewrittenMasterLines[rewrittenMasterLines.length - 1] = localVariantManifestFileName;
              variantLinked = true; // Link only once
            }
          }
        } else if (line.endsWith('.m3u8') && !line.startsWith('#') && !variantLinked) {
          // Handle direct variant list without #EXT-X-STREAM-INF
          rewrittenMasterLines[rewrittenMasterLines.length - 1] = localVariantManifestFileName;
          variantLinked = true;
        }
      }

      // Fallback: If no variant was found and rewritten, ensure the local master manifest directly points to segments if applicable.
      // (This scenario implies selectedVariantPlaylistUrl was the master HLS URL itself)
      if (!variantLinked && selectedVariantPlaylistUrl == hlsUrl) {
        // In this case, the master manifest is essentially the variant manifest,
        // so we just ensure it's written and points to local segments.
        // The content should already be rewritten to local paths from step 5,
        // so simply write the new local master manifest based on the variant one.
        // For simplicity, if we don't find a variant, we will just use the *downloaded* local variant manifest (which might be the master itself)
        // as the primary entry point for playback.
        // This block ensures the master manifest is correctly updated if it was itself the one containing segments.
        await localMasterManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
      } else {
        await localMasterManifestFile.writeAsString(rewrittenMasterLines.join('\n'));
      }


      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      // Return the path to the local master manifest as the entry point
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
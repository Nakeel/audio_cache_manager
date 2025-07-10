// lib/data/services/hls_cache_handler.dart

import 'dart:io';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http show ClientException, Response, get;
import 'package:path/path.dart' as p;


class HlsCacheHandler {

  static const int _maxSegmentRetries = 3; // Max retries per segment
  static const Duration _retryDelay = Duration(seconds: 2); // Initial delay

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
      AppLogger.info('Downloading HLS master manifest from $hlsUrl', name: 'HlsCacheHandler');
      final http.Response masterManifestResponse = await http.get(hlsUri);
      if (masterManifestResponse.statusCode != 200) {
        throw Exception('Failed to download HLS master manifest: ${masterManifestResponse.statusCode}');
      }

      final String masterManifestContent = masterManifestResponse.body;
      final List<String> masterManifestOriginalLines = masterManifestContent.split('\n');

      // 2. Parse Master Manifest for *All* Variant and Media Playlists
      // Map: original_relative_uri_from_master -> absolute_resolved_url
      final Map<String, String> playlistUrisToDownload = {};
      final RegExp streamInfPattern = RegExp(r'^#EXT-X-STREAM-INF.*', multiLine: true);
      // Regex to capture the URI inside URI="..." for #EXT-X-MEDIA tags
      final RegExp mediaInfPattern = RegExp(r'^#EXT-X-MEDIA:.*URI="([^"]+)".*', multiLine: true);

      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String currentLine = masterManifestOriginalLines[i].trim();

        // Handle #EXT-X-STREAM-INF (video/audio variants with bandwidth info)
        if (streamInfPattern.hasMatch(currentLine)) {
          // The URI for the variant playlist is on the *next* line
          if (i + 1 < masterManifestOriginalLines.length) {
            final String nextLine = masterManifestOriginalLines[i + 1].trim();
            if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
              final String absoluteUrl = _resolveUri(hlsUri, nextLine).toString();
              playlistUrisToDownload[nextLine] = absoluteUrl; // Store original relative path and absolute URL
              AppLogger.info('Found variant playlist (stream-inf): $absoluteUrl', name: 'HlsCacheHandler');
            }
          }
        }
        // Handle #EXT-X-MEDIA (audio/subtitles that have URI="...")
        else if (mediaInfPattern.firstMatch(currentLine) != null) { // Corrected: This `else if` is now correctly chained
          final Match mediaMatch = mediaInfPattern.firstMatch(currentLine)!; // Assert non-null after the `else if` check
          final String? uriInQuote = mediaMatch.group(1); // Extract the content of URI="..."
          if (uriInQuote != null && uriInQuote.endsWith('.m3u8')) {
            final String absoluteUrl = _resolveUri(hlsUri, uriInQuote).toString();
            playlistUrisToDownload[uriInQuote] = absoluteUrl; // Store original relative path and absolute URL
            AppLogger.info('Found media playlist (media-inf): $absoluteUrl', name: 'HlsCacheHandler');
          }
        }
        // Fallback: If master manifest directly lists .m3u8 files without EXT-X-STREAM-INF/MEDIA
        // This is less common for master manifests, but good for robustness.
        else if (!currentLine.startsWith('#') && currentLine.endsWith('.m3u8')) { // Corrected: This `else if` is now correctly chained
          final String absoluteUrl = _resolveUri(hlsUri, currentLine).toString();
          if (!playlistUrisToDownload.containsKey(currentLine)) { // Avoid duplicates if already caught by other patterns
            playlistUrisToDownload[currentLine] = absoluteUrl;
            AppLogger.info('Found direct variant playlist (no EXT-X-STREAM-INF/MEDIA): $absoluteUrl', name: 'HlsCacheHandler');
          }
        }
      }

      // Handle case where master manifest itself is the segment list (no explicit variants)
      if (playlistUrisToDownload.isEmpty) {
        AppLogger.warning('No explicit variant HLS playlists found in master manifest. Attempting to treat master as direct segment list.', name: 'HlsCacheHandler');
        playlistUrisToDownload[p.basename(hlsUri.path)] = hlsUrl; // Use master URL as the "variant"
      }

      // New Step: Store the actual local paths of the rewritten variant manifests
      // Map: original_relative_uri_from_master -> local_file_path_of_rewritten_variant_manifest
      final Map<String, String> localRewrittenManifestPaths = {};

      // 3. Download *All* Identified Variant/Media Playlists and their Segments
      int totalSegmentsOverall = 0;
      int downloadedSegmentsOverall = 0;

      onProgress?.call(0, playlistUrisToDownload.length); // Initial progress based on playlist count

      for (final MapEntry<String, String> entry in playlistUrisToDownload.entries) {
        final String originalRelativeUri = entry.key; // e.g., "video/500kbit.m3u8" or "audio/stereo/en/128kbit.m3u8"
        final String absoluteVariantUrl = entry.value; // e.g., "http://example.com/video/500kbit.m3u8"

        AppLogger.info('Processing variant playlist: $absoluteVariantUrl', name: 'HlsCacheHandler');
        final Uri variantUri = Uri.parse(absoluteVariantUrl);
        final http.Response variantManifestResponse = await http.get(variantUri);
        if (variantManifestResponse.statusCode != 200) {
          AppLogger.error('Failed to download variant manifest $absoluteVariantUrl: HTTP ${variantManifestResponse.statusCode}. Skipping this variant.', name: 'HlsCacheHandler');
          continue; // Skip this variant if its manifest can't be downloaded
        }

        final String variantManifestContent = variantManifestResponse.body;
        final List<String> variantManifestLines = variantManifestContent.split('\n');

        // 4. Parse Variant Playlist for Media Segments and Download
        final List<String> rewrittenVariantLines = [];
        int segmentsInThisVariant = 0;
        int downloadedSegmentsInThisVariant = 0;

        for (final line in variantManifestLines) {
          final trimmedLine = line.trim();
          // Add original line first. If it's a segment URI, it will be overwritten below.
          rewrittenVariantLines.add(line);

          // Robust segment detection:
          // - Not a comment/directive line
          // - Ends with a common media segment extension (.ts, .mp4)
          // - Does NOT contain '.m3u8' (to avoid confusing with nested playlists within variants, which is rare but possible)
          if (!trimmedLine.startsWith('#') &&
              (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.mp4')) &&
              !trimmedLine.contains('.m3u8')) {

            segmentsInThisVariant++;
            totalSegmentsOverall++; // Increment total segment count for overall progress

            final Uri segmentUri = _resolveUri(variantUri, trimmedLine); // Resolve relative segment URI against variant manifest URI
            final String segmentFileName = p.basename(segmentUri.path);
            final String localSegmentPath = p.join(hlsCacheDirPath, segmentFileName);

            // Rewrite the manifest line to point to the local filename
            rewrittenVariantLines[rewrittenVariantLines.length - 1] = segmentFileName;

            // --- Segment Download with Retry Logic ---
            bool segmentDownloadedSuccessfully = false;
            int retries = 0;
            while (!segmentDownloadedSuccessfully && retries < _maxSegmentRetries) {
              try {
                AppLogger.info('Downloading segment: $segmentUri (Attempt ${retries + 1}/${_maxSegmentRetries})', name: 'HlsCacheHandler');
                final http.Response segmentResponse = await http.get(segmentUri);
                if (segmentResponse.statusCode == 200) {
                  final File segmentFile = File(localSegmentPath);
                  await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
                  downloadedSegmentsInThisVariant++;
                  downloadedSegmentsOverall++; // Increment downloaded segment count for overall progress
                  AppLogger.info('Downloaded segment to: $localSegmentPath', name: 'HlsCacheHandler');
                  segmentDownloadedSuccessfully = true;
                } else {
                  AppLogger.warning('Failed to download segment $segmentUri: HTTP ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
                  retries++;
                  await Future.delayed(_retryDelay * (retries + 1)); // Exponential backoff for delay
                }
              } on SocketException catch (e) {
                AppLogger.error('SocketException downloading segment $segmentUri (Attempt ${retries + 1}): $e. Retrying...', error: e, name: 'HlsCacheHandler');
                retries++;
                await Future.delayed(_retryDelay * (retries + 1));
              } on http.ClientException catch (e) {
                AppLogger.error('ClientException downloading segment $segmentUri (Attempt ${retries + 1}): $e. Retrying...', error: e, name: 'HlsCacheHandler');
                retries++;
                await Future.delayed(_retryDelay * (retries + 1));
              } catch (e, st) {
                AppLogger.error('Unexpected error downloading segment $segmentUri: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
                // For other unexpected errors, don't retry, just break for this segment
                break;
              }
            }

            if (!segmentDownloadedSuccessfully) {
              AppLogger.error('Failed to download segment $segmentUri after $_maxSegmentRetries attempts. This segment will be missing.', name: 'HlsCacheHandler');
              // Depending on requirements, you might want to mark the entire cache as failed
              // or just tolerate missing segments. For now, we continue.
            }
          }
        }

        AppLogger.info('Variant ${p.basename(absoluteVariantUrl)}: Found $segmentsInThisVariant segments. Downloaded $downloadedSegmentsInThisVariant.', name: 'HlsCacheHandler');

        // Save the rewritten variant manifest
        final String localVariantManifestFileName = p.basename(variantUri.path); // Use basename of the absolute resolved URI
        final String localVariantManifestPath = p.join(hlsCacheDirPath, localVariantManifestFileName);
        final File localVariantManifestFile = File(localVariantManifestPath);
        await localVariantManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
        localRewrittenManifestPaths[originalRelativeUri] = localVariantManifestFile.path; // Store the local path
        AppLogger.info('Rewritten local variant manifest saved to: ${localVariantManifestFile.path}', name: 'HlsCacheHandler');
        onProgress?.call(downloadedSegmentsOverall, totalSegmentsOverall); // Update overall progress after each variant is done
      }

      AppLogger.info('Overall: Found $totalSegmentsOverall segments. Downloaded $downloadedSegmentsOverall.', name: 'HlsCacheHandler');

      // 5. Rewrite Local Master Manifest to point to *all* local variant/media manifests
      final String localMasterManifestFileName = p.basename(hlsUri.path); // Usually 'playlist.m3u8'
      final String localMasterManifestPath = p.join(hlsCacheDirPath, localMasterManifestFileName);
      final File localMasterManifestFile = File(localMasterManifestPath);

      final List<String> rewrittenMasterLines = [];
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String originalLine = masterManifestOriginalLines[i];
        final String trimmedLine = originalLine.trim();

        bool lineHandled = false;

        // Check for #EXT-X-STREAM-INF and its subsequent URI
        if (streamInfPattern.hasMatch(trimmedLine) && i + 1 < masterManifestOriginalLines.length) {
          final String nextLineOriginalUri = masterManifestOriginalLines[i + 1].trim();
          if (!nextLineOriginalUri.startsWith('#') && nextLineOriginalUri.endsWith('.m3u8')) {
            if (localRewrittenManifestPaths.containsKey(nextLineOriginalUri)) {
              // Add the #EXT-X-STREAM-INF line as is
              rewrittenMasterLines.add(originalLine);
              // Add the rewritten URI line, pointing to the local filename
              rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[nextLineOriginalUri]!));
              i++; // Increment i to skip the URI line, as we've already processed it
              lineHandled = true;
            }
          }
        }
        // Check for #EXT-X-MEDIA and its URI (subtitles, alternate audio)
        // This requires parsing and rewriting the URI within the same line
        else if (mediaInfPattern.firstMatch(trimmedLine) != null) { // Corrected: This `else if` is now correctly chained
          final Match mediaMatch = mediaInfPattern.firstMatch(trimmedLine)!; // Assert non-null after the `else if` check
          final String? uriInQuote = mediaMatch.group(1);
          if (uriInQuote != null && uriInQuote.endsWith('.m3u8')) {
            if (localRewrittenManifestPaths.containsKey(uriInQuote)) {
              // Replace the original URI within the line with just the local filename
              final String localFilename = p.basename(localRewrittenManifestPaths[uriInQuote]!);
              rewrittenMasterLines.add(trimmedLine.replaceAll('URI="$uriInQuote"', 'URI="$localFilename"'));
              lineHandled = true;
            }
          }
        }

        // Fallback for direct .m3u8 line without EXT-X-STREAM-INF/MEDIA (less common for master)
        else if (!lineHandled && !trimmedLine.startsWith('#') && trimmedLine.endsWith('.m3u8')) { // Corrected: This `else if` is now correctly chained
          if (localRewrittenManifestPaths.containsKey(trimmedLine)) {
            rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[trimmedLine]!));
            lineHandled = true;
          }
        }

        if (!lineHandled) {
          rewrittenMasterLines.add(originalLine); // Add line as is if it's not a URI that needs rewriting
        }
      }

      await localMasterManifestFile.writeAsString(rewrittenMasterLines.join('\n'));
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
    // Correctly resolve relative path, handling cases where baseUri.path might not end with a '/'
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
import 'dart:io';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';

class HlsCacheHandler {

  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);
  // Concurrency limits removed as we are going sequential

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
      AppLogger.info('Downloading HLS master manifest from $hlsUrl', name: 'HlsCacheHandler');
      final http.Response masterManifestResponse = await http.get(hlsUri);
      if (masterManifestResponse.statusCode != 200) {
        throw Exception('Failed to download HLS master manifest: ${masterManifestResponse.statusCode}');
      }

      final String masterManifestContent = masterManifestResponse.body;
      final List<String> masterManifestOriginalLines = masterManifestContent.split('\n');

      // 2. Parse Master Manifest to select the SMALLEST Bandwidth Variant and its Associated Audio
      String? selectedVideoVariantRelativeUri;
      String? selectedVideoVariantAbsoluteUrl;
      int minBandwidth = 2147483647; // Initialize with Dart's max int value

      String? selectedAudioRelativeUri; // For separate audio streams
      String? selectedAudioAbsoluteUrl;
      String? selectedAudioGroupId; // To link audio to video variant

      final RegExp streamInfPattern = RegExp(r'^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+).*(RESOLUTION=(\d+x\d+))?.*(AUDIO="([^"]+)")?.*', multiLine: true);
      final RegExp mediaInfPattern = RegExp(r'^#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="([^"]+)".*URI="([^"]+)".*(DEFAULT=(YES|NO))?', multiLine: true);
      final RegExp subtitleMediaInfPattern = RegExp(r'^#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="([^"]+)".*URI="([^"]+)".*(DEFAULT=(YES|NO))?', multiLine: true);

      // First pass: Identify smallest bandwidth video variant
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String currentLine = masterManifestOriginalLines[i].trim();

        if (streamInfPattern.hasMatch(currentLine)) {
          final Match? streamMatch = streamInfPattern.firstMatch(currentLine);
          if (streamMatch != null) {
            final int bandwidth = int.parse(streamMatch.group(1)!);
            final String? audioGroupId = streamMatch.group(5); // Capture the AUDIO="group_id" part

            if (bandwidth < minBandwidth) { // Logic changed to select smallest bandwidth
              minBandwidth = bandwidth;
              if (i + 1 < masterManifestOriginalLines.length) {
                final String nextLine = masterManifestOriginalLines[i + 1].trim();
                if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
                  selectedVideoVariantRelativeUri = nextLine;
                  selectedVideoVariantAbsoluteUrl = _resolveUri(hlsUri, nextLine).toString();
                  selectedAudioGroupId = audioGroupId; // Store associated audio group ID
                  AppLogger.info('Found new smallest video variant (BANDWIDTH: $bandwidth): $selectedVideoVariantAbsoluteUrl', name: 'HlsCacheHandler');
                }
              }
            }
          }
        }
      }

      // Second pass: Find default/best audio for the selected video variant (if an audio group was linked)
      if (selectedAudioGroupId != null) {
        final Map<String, String> audioTracksInGroup = {};
        String? defaultAudioUri;
        String? defaultAudioAbsoluteUrl;

        for (final line in masterManifestOriginalLines) {
          final String trimmedLine = line.trim();
          final Match? mediaMatch = mediaInfPattern.firstMatch(trimmedLine);
          if (mediaMatch != null) {
            final String groupId = mediaMatch.group(1)!;
            final String audioUri = mediaMatch.group(2)!;
            final String isDefault = mediaMatch.group(4) ?? 'NO';

            if (groupId == selectedAudioGroupId) {
              final String absoluteAudioUrl = _resolveUri(hlsUri, audioUri).toString();
              audioTracksInGroup[audioUri] = absoluteAudioUrl;
              if (isDefault == 'YES') {
                defaultAudioUri = audioUri;
                defaultAudioAbsoluteUrl = absoluteAudioUrl;
                AppLogger.info('Found default audio for group $selectedAudioGroupId: $absoluteAudioUrl', name: 'HlsCacheHandler');
              }
            }
          }
        }
        if (defaultAudioUri != null) {
          selectedAudioRelativeUri = defaultAudioUri;
          selectedAudioAbsoluteUrl = defaultAudioAbsoluteUrl;
        } else if (audioTracksInGroup.isNotEmpty) {
          selectedAudioRelativeUri = audioTracksInGroup.keys.first;
          selectedAudioAbsoluteUrl = audioTracksInGroup.values.first;
          AppLogger.warning('No default audio found for group $selectedAudioGroupId. Picking first available: $selectedAudioAbsoluteUrl', name: 'HlsCacheHandler');
        }
      }

      // What if there are no EXT-X-STREAM-INF (audio-only HLS)?
      if (selectedVideoVariantAbsoluteUrl == null) {
        AppLogger.info('No video variants found. Searching for audio-only streams.', name: 'HlsCacheHandler');
        minBandwidth = 2147483647; // Reset for audio-only selection
        for (int i = 0; i < masterManifestOriginalLines.length; i++) {
          final String currentLine = masterManifestOriginalLines[i].trim();
          if (streamInfPattern.hasMatch(currentLine)) {
            final Match? streamMatch = streamInfPattern.firstMatch(currentLine);
            if (streamMatch != null && streamMatch.group(2) == null) { // No RESOLUTION likely audio-only
              final int bandwidth = int.parse(streamMatch.group(1)!);
              if (bandwidth < minBandwidth) { // Select smallest bandwidth audio-only
                minBandwidth = bandwidth;
                if (i + 1 < masterManifestOriginalLines.length) {
                  final String nextLine = masterManifestOriginalLines[i + 1].trim();
                  if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
                    selectedVideoVariantRelativeUri = nextLine;
                    selectedVideoVariantAbsoluteUrl = _resolveUri(hlsUri, nextLine).toString();
                    AppLogger.info('Found smallest audio-only variant (BANDWIDTH: $bandwidth): $selectedVideoVariantAbsoluteUrl', name: 'HlsCacheHandler');
                  }
                }
              }
            }
          }
        }
        if (selectedVideoVariantAbsoluteUrl == null) {
          AppLogger.warning('No standard video or audio-only variants identified. Assuming master manifest is the direct segment list.', name: 'HlsCacheHandler');
          selectedVideoVariantRelativeUri = p.basename(hlsUri.path);
          selectedVideoVariantAbsoluteUrl = hlsUrl;
        }
      }

      if (selectedVideoVariantAbsoluteUrl == null && selectedAudioAbsoluteUrl == null) {
        throw Exception('Could not identify a suitable variant (video or audio) to cache from the HLS master manifest.');
      }

      final Map<String, String> localRewrittenManifestPaths = {};
      final Map<String, String> playlistsToProcess = {};

      if (selectedVideoVariantRelativeUri != null && selectedVideoVariantAbsoluteUrl != null) {
        playlistsToProcess[selectedVideoVariantRelativeUri!] = selectedVideoVariantAbsoluteUrl!;
      }
      if (selectedAudioRelativeUri != null && selectedAudioAbsoluteUrl != null) {
        if (selectedVideoVariantRelativeUri == null || selectedVideoVariantRelativeUri != selectedAudioRelativeUri) {
          playlistsToProcess[selectedAudioRelativeUri!] = selectedAudioAbsoluteUrl!;
        }
      }

      // Initialize progress tracking
      int totalSegmentsOverall = 0;
      int downloadedSegmentsOverall = 0;

      // First, determine total segments by downloading and parsing all selected variant manifests
      // This is done sequentially to get the accurate total count before downloads begin
      for (final MapEntry<String, String> entry in playlistsToProcess.entries) {
        final String absoluteVariantUrl = entry.value;
        AppLogger.info('Discovering segments for variant: $absoluteVariantUrl', name: 'HlsCacheHandler');
        final Uri variantUri = Uri.parse(absoluteVariantUrl);
        final http.Response variantManifestResponse = await http.get(variantUri); // Sequential download of manifest
        if (variantManifestResponse.statusCode != 200) {
          AppLogger.error('Failed to download variant manifest $absoluteVariantUrl: HTTP ${variantManifestResponse.statusCode}. Skipping segment count for this variant.', name: 'HlsCacheHandler');
          continue;
        }
        final String variantManifestContent = variantManifestResponse.body;
        final List<String> variantManifestLines = variantManifestContent.split('\n');

        for (final line in variantManifestLines) {
          final trimmedLine = line.trim();
          if (!trimmedLine.startsWith('#') &&
              (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.mp4')) &&
              !trimmedLine.contains('.m3u8')) {
            totalSegmentsOverall++; // Count segments to set total for progress
          }
        }
      }

      AppLogger.info('Total segments identified for sequential download: $totalSegmentsOverall', name: 'HlsCacheHandler');
      onProgress?.call(0, totalSegmentsOverall); // Initialize progress with total count


      // 3. Download Selected Variant Manifest(s) and their Segments Sequentially
      for (final MapEntry<String, String> entry in playlistsToProcess.entries) {
        final String originalRelativeUri = entry.key;
        final String absoluteVariantUrl = entry.value;

        AppLogger.info('Processing variant: $absoluteVariantUrl', name: 'HlsCacheHandler');
        final Uri variantUri = Uri.parse(absoluteVariantUrl);
        // We've already downloaded this to count segments, could potentially optimize by reusing content
        // For simplicity and robustness against stale content, redownloading here.
        final http.Response variantManifestResponse = await http.get(variantUri);
        if (variantManifestResponse.statusCode != 200) {
          AppLogger.error('Failed to download variant manifest $absoluteVariantUrl: HTTP ${variantManifestResponse.statusCode}. Skipping this variant.', name: 'HlsCacheHandler');
          continue;
        }

        final String variantManifestContent = variantManifestResponse.body;
        final List<String> variantManifestLines = variantManifestContent.split('\n');

        // 4. Parse Variant Playlist for Media Segments and Download Sequentially
        final List<String> rewrittenVariantLines = [];

        for (final line in variantManifestLines) {
          final trimmedLine = line.trim();
          rewrittenVariantLines.add(line); // Add original line first

          if (!trimmedLine.startsWith('#') &&
              (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.mp4')) &&
              !trimmedLine.contains('.m3u8')) {

            final Uri segmentUri = _resolveUri(variantUri, trimmedLine);
            final String segmentFileName = p.basename(segmentUri.path);
            final String localSegmentPath = p.join(hlsCacheDirPath, segmentFileName);

            // Rewrite the manifest line to point to the local filename
            rewrittenVariantLines[rewrittenVariantLines.length - 1] = segmentFileName;

            // --- Segment Download with Retry Logic (Sequential) ---
            bool segmentDownloadedSuccessfully = false;
            int retries = 0;
            while (!segmentDownloadedSuccessfully && retries < _maxSegmentRetries) {
              try {
                AppLogger.info('Downloading segment: $segmentUri (Attempt ${retries + 1}/${_maxSegmentRetries})', name: 'HlsCacheHandler');
                final http.Response segmentResponse = await http.get(segmentUri); // Sequential download
                if (segmentResponse.statusCode == 200) {
                  final File segmentFile = File(localSegmentPath);
                  await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
                  downloadedSegmentsOverall++; // Update overall downloaded count
                  onProgress?.call(downloadedSegmentsOverall, totalSegmentsOverall); // Report progress
                  AppLogger.info('Downloaded segment to: $localSegmentPath', name: 'HlsCacheHandler');
                  segmentDownloadedSuccessfully = true;
                } else {
                  AppLogger.warning('Failed to download segment $segmentUri: HTTP ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
                  retries++;
                  await Future.delayed(_retryDelay * (retries + 1));
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
                break; // For other unexpected errors, don't retry, just break for this segment
              }
            }

            if (!segmentDownloadedSuccessfully) {
              AppLogger.error('Failed to download segment $segmentUri after $_maxSegmentRetries attempts. This segment will be missing.', name: 'HlsCacheHandler');
            }
          }
        }

        // Save the rewritten variant manifest
        final String localVariantManifestFileName = p.basename(variantUri.path);
        final String localVariantManifestPath = p.join(hlsCacheDirPath, localVariantManifestFileName);
        final File localVariantManifestFile = File(localVariantManifestPath);
        await localVariantManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
        localRewrittenManifestPaths[originalRelativeUri] = localVariantManifestFile.path;
        AppLogger.info('Rewritten local variant manifest saved to: ${localVariantManifestFile.path}', name: 'HlsCacheHandler');
      }

      AppLogger.info('Overall: Found $totalSegmentsOverall segments. Downloaded $downloadedSegmentsOverall.', name: 'HlsCacheHandler');

      // 5. Rewrite Local Master Manifest to point to *only* the selected local variant(s)
      final String localMasterManifestFileName = p.basename(hlsUri.path);
      final String localMasterManifestPath = p.join(hlsCacheDirPath, localMasterManifestFileName);
      final File localMasterManifestFile = File(localMasterManifestPath);

      final List<String> rewrittenMasterLines = [];
      bool inStreamInfBlock = false;
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String originalLine = masterManifestOriginalLines[i];
        final String trimmedLine = originalLine.trim();

        if (inStreamInfBlock) {
          inStreamInfBlock = false;
          continue;
        }

        if (streamInfPattern.hasMatch(trimmedLine)) {
          final Match? streamMatch = streamInfPattern.firstMatch(trimmedLine);
          if (streamMatch != null && i + 1 < masterManifestOriginalLines.length) {
            final String nextLineOriginalUri = masterManifestOriginalLines[i + 1].trim();
            if (selectedVideoVariantRelativeUri == nextLineOriginalUri) {
              rewrittenMasterLines.add(originalLine);
              rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[nextLineOriginalUri]!));
              inStreamInfBlock = true;
            }
          }
        }
        else if (mediaInfPattern.hasMatch(trimmedLine)) {
          final Match? mediaMatch = mediaInfPattern.firstMatch(trimmedLine);
          if (mediaMatch != null) {
            final String? uriInQuote = mediaMatch.group(2);
            if (selectedAudioRelativeUri == uriInQuote) {
              final String localFilename = p.basename(localRewrittenManifestPaths[uriInQuote!]!);
              rewrittenMasterLines.add(trimmedLine.replaceAll('URI="$uriInQuote"', 'URI="$localFilename"'));
            }
          }
        }
        else if (selectedVideoVariantRelativeUri == trimmedLine && !trimmedLine.startsWith('#') && trimmedLine.endsWith('.m3u8')) {
          rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[trimmedLine]!));
        }
        else if (trimmedLine.startsWith('#') &&
            !streamInfPattern.hasMatch(trimmedLine) &&
            !mediaInfPattern.hasMatch(trimmedLine) &&
            !subtitleMediaInfPattern.hasMatch(trimmedLine)) {
          rewrittenMasterLines.add(originalLine);
        }
      }

      await localMasterManifestFile.writeAsString(rewrittenMasterLines.join('\n'));
      AppLogger.info('Rewritten HLS master manifest (single variant) saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      AppLogger.info('HLS caching complete for track $trackId. Local manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
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
// lib/data/services/hls_cache_handler.dart

import 'dart:async' show Completer;
import 'dart:collection' show Queue;
import 'dart:io';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http show ClientException, Response, get;
import 'package:path/path.dart' as p;

class HlsCacheHandler {

  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);
  static const int _maxConcurrentSegmentDownloads = 8; // Limit for concurrent segment downloads

  /// Caches an HLS stream, downloading a single chosen variant and its segments.
  /// Returns the local path to the rewritten master manifest.
  ///
  /// By default, it attempts to select the highest bandwidth video variant
  /// and its associated audio track.
  Future<String?> cacheHls(
      String hlsUrl,
      String cacheBaseDirPath,
      String trackId, {
        Function(int received, int total)? onProgress,
        // Optional: you could add parameters here to select a specific variant,
        // e.g., preferredBandwidth, preferredLanguage, etc.
      }) async {
    AppLogger.info('Attempting to cache SINGLE HLS variant: $hlsUrl for track $trackId', name: 'HlsCacheHandler');

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

      // 2. Parse Master Manifest to select the BEST Variant and its Associated Audio
      String? selectedVideoVariantRelativeUri;
      String? selectedVideoVariantAbsoluteUrl;
      int maxBandwidth = -1;

      String? selectedAudioRelativeUri; // For separate audio streams
      String? selectedAudioAbsoluteUrl;
      String? selectedAudioGroupId; // To link audio to video variant

      final RegExp streamInfPattern = RegExp(r'^#EXT-X-STREAM-INF:.*BANDWIDTH=(\d+).*(RESOLUTION=(\d+x\d+))?.*(AUDIO="([^"]+)")?.*', multiLine: true);
      final RegExp mediaInfPattern = RegExp(r'^#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="([^"]+)".*URI="([^"]+)".*(DEFAULT=(YES|NO))?', multiLine: true);
      // For subtitles, you might want to extend this to select a default subtitle if needed
      final RegExp subtitleMediaInfPattern = RegExp(r'^#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="([^"]+)".*URI="([^"]+)".*(DEFAULT=(YES|NO))?', multiLine: true);


      // First pass: Identify highest bandwidth video variant
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String currentLine = masterManifestOriginalLines[i].trim();

        if (streamInfPattern.hasMatch(currentLine)) {
          final Match? streamMatch = streamInfPattern.firstMatch(currentLine);
          if (streamMatch != null) {
            final int bandwidth = int.parse(streamMatch.group(1)!);
            final String? audioGroupId = streamMatch.group(5); // Capture the AUDIO="group_id" part

            if (bandwidth > maxBandwidth) {
              maxBandwidth = bandwidth;
              if (i + 1 < masterManifestOriginalLines.length) {
                final String nextLine = masterManifestOriginalLines[i + 1].trim();
                if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
                  selectedVideoVariantRelativeUri = nextLine;
                  selectedVideoVariantAbsoluteUrl = _resolveUri(hlsUri, nextLine).toString();
                  selectedAudioGroupId = audioGroupId; // Store associated audio group ID
                  AppLogger.info('Found new best video variant (BANDWIDTH: $bandwidth): $selectedVideoVariantAbsoluteUrl', name: 'HlsCacheHandler');
                }
              }
            }
          }
        }
      }

      // Second pass: Find default/best audio for the selected video variant (if an audio group was linked)
      if (selectedAudioGroupId != null) {
        // Collect all audio tracks for the selected group
        final Map<String, String> audioTracksInGroup = {}; // uri -> absolute url
        String? defaultAudioUri;
        String? defaultAudioAbsoluteUrl;

        for (final line in masterManifestOriginalLines) {
          final String trimmedLine = line.trim();
          final Match? mediaMatch = mediaInfPattern.firstMatch(trimmedLine);
          if (mediaMatch != null) {
            final String groupId = mediaMatch.group(1)!;
            final String audioUri = mediaMatch.group(2)!;
            final String isDefault = mediaMatch.group(4) ?? 'NO'; // group(4) is YES/NO

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
        // If a default audio was found in the group, use it. Otherwise, pick the first available.
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
        // Find the highest bandwidth audio-only variant or a default audio MEDIA if no video
        maxBandwidth = -1; // Reset for audio-only
        for (int i = 0; i < masterManifestOriginalLines.length; i++) {
          final String currentLine = masterManifestOriginalLines[i].trim();
          if (streamInfPattern.hasMatch(currentLine)) { // Re-using streamInfPattern for audio-only streams sometimes
            final Match? streamMatch = streamInfPattern.firstMatch(currentLine);
            if (streamMatch != null && streamMatch.group(2) == null) { // No RESOLUTION means it's likely audio-only
              final int bandwidth = int.parse(streamMatch.group(1)!);
              if (bandwidth > maxBandwidth) {
                maxBandwidth = bandwidth;
                if (i + 1 < masterManifestOriginalLines.length) {
                  final String nextLine = masterManifestOriginalLines[i + 1].trim();
                  if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
                    selectedVideoVariantRelativeUri = nextLine; // This will now represent the audio-only stream
                    selectedVideoVariantAbsoluteUrl = _resolveUri(hlsUri, nextLine).toString();
                    AppLogger.info('Found best audio-only variant (BANDWIDTH: $bandwidth): $selectedVideoVariantAbsoluteUrl', name: 'HlsCacheHandler');
                  }
                }
              }
            }
          }
        }
        // If still no video/audio-only variant found, and it's a simple direct m3u8.
        if (selectedVideoVariantAbsoluteUrl == null) {
          AppLogger.warning('No standard video or audio-only variants identified. Assuming master manifest is the direct segment list.', name: 'HlsCacheHandler');
          selectedVideoVariantRelativeUri = p.basename(hlsUri.path); // Use master's filename
          selectedVideoVariantAbsoluteUrl = hlsUrl;
        }
      }


      if (selectedVideoVariantAbsoluteUrl == null && selectedAudioAbsoluteUrl == null) {
        throw Exception('Could not identify a suitable variant (video or audio) to cache from the HLS master manifest.');
      }

      // Map: original_relative_uri_from_master -> local_file_path_of_rewritten_variant_manifest
      final Map<String, String> localRewrittenManifestPaths = {};
      final Map<String, String> playlistsToProcess = {};

      if (selectedVideoVariantRelativeUri != null && selectedVideoVariantAbsoluteUrl != null) {
        playlistsToProcess[selectedVideoVariantRelativeUri!] = selectedVideoVariantAbsoluteUrl!;
      }
      if (selectedAudioRelativeUri != null && selectedAudioAbsoluteUrl != null) {
        // Ensure audio is added only if it's a separate manifest and not already the selected video variant
        if (selectedVideoVariantRelativeUri == null || selectedVideoVariantRelativeUri != selectedAudioRelativeUri) {
          playlistsToProcess[selectedAudioRelativeUri!] = selectedAudioAbsoluteUrl!;
        }
      }

      // Initialize progress tracking
      int totalSegmentsOverall = 0;
      int downloadedSegmentsOverall = 0;

      // Use a Completer to know when segment counts for all chosen playlists are finalized
      final Completer<void> segmentCountDiscoveryCompleter = Completer<void>();
      int playlistsToProcessCount = playlistsToProcess.length;
      int playlistsProcessedForCount = 0;


      // Process the selected variant(s)
      final List<Future<void>> processingTasks = [];
      for (final MapEntry<String, String> entry in playlistsToProcess.entries) {
        processingTasks.add(_processSingleVariant(
          hlsUri, // Pass master HLS URI for correct path resolution if needed
          entry.key, // Original relative URI
          entry.value, // Absolute URL of the playlist
          hlsCacheDirPath,
          localRewrittenManifestPaths,
              (segmentsFound) {
            totalSegmentsOverall += segmentsFound;
            playlistsProcessedForCount++;
            if (playlistsProcessedForCount == playlistsToProcessCount) {
              segmentCountDiscoveryCompleter.complete();
            }
          },
              (downloaded) {
            downloadedSegmentsOverall += downloaded;
            onProgress?.call(downloadedSegmentsOverall, totalSegmentsOverall);
          },
        ));
      }

      // Wait for segment counts to be discovered before proceeding, then wait for all downloads
      if (playlistsToProcess.isNotEmpty) {
        await Future.wait([
          Future.wait(processingTasks), // Wait for all processing tasks to complete
          segmentCountDiscoveryCompleter.future, // Wait for total segments to be known
        ]);
      } else {
        AppLogger.warning('No playlists were selected for processing.', name: 'HlsCacheHandler');
      }

      AppLogger.info('Overall: Found $totalSegmentsOverall segments. Downloaded $downloadedSegmentsOverall.', name: 'HlsCacheHandler');

      // 5. Rewrite Local Master Manifest to point to *only* the selected local variant(s)
      final String localMasterManifestFileName = p.basename(hlsUri.path); // Usually 'playlist.m3u8'
      final String localMasterManifestPath = p.join(hlsCacheDirPath, localMasterManifestFileName);
      final File localMasterManifestFile = File(localMasterManifestPath);

      final List<String> rewrittenMasterLines = [];
      bool inStreamInfBlock = false; // To handle skipping next line if it's a stream URI
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String originalLine = masterManifestOriginalLines[i];
        final String trimmedLine = originalLine.trim();

        if (inStreamInfBlock) {
          inStreamInfBlock = false; // Reset for next line
          continue; // Skip the URI line of the EXT-X-STREAM-INF that was just processed
        }

        // Process #EXT-X-STREAM-INF
        if (streamInfPattern.hasMatch(trimmedLine)) {
          final Match? streamMatch = streamInfPattern.firstMatch(trimmedLine);
          if (streamMatch != null && i + 1 < masterManifestOriginalLines.length) {
            final String nextLineOriginalUri = masterManifestOriginalLines[i + 1].trim();
            // If this is our selected video variant, rewrite its URI
            if (selectedVideoVariantRelativeUri == nextLineOriginalUri) {
              rewrittenMasterLines.add(originalLine); // Add the EXT-X-STREAM-INF line
              rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[nextLineOriginalUri]!)); // Add local path
              inStreamInfBlock = true; // Mark to skip the next line
            }
            // Else, skip this stream-inf block (don't add originalLine or nextLine)
          }
        }
        // Process #EXT-X-MEDIA (audio/subtitles)
        else if (mediaInfPattern.hasMatch(trimmedLine)) {
          final Match? mediaMatch = mediaInfPattern.firstMatch(trimmedLine);
          if (mediaMatch != null) {
            final String? uriInQuote = mediaMatch.group(2); // The URI attribute
            // If this is our selected audio variant, rewrite its URI
            if (selectedAudioRelativeUri == uriInQuote) {
              final String localFilename = p.basename(localRewrittenManifestPaths[uriInQuote!]!);
              rewrittenMasterLines.add(trimmedLine.replaceAll('URI="$uriInQuote"', 'URI="$localFilename"'));
            }
            // Else, skip this media line (don't add originalLine)
          }
        }
        // Handle #EXT-X-MEDIA for SUBTITLES if needed (optional - currently not caching)
        // else if (subtitleMediaInfPattern.hasMatch(trimmedLine)) {
        //     // If you want to cache a default subtitle, add similar logic here
        //     // Otherwise, it will be skipped by default.
        // }
        // Fallback for direct .m3u8 line (if master is just segments)
        else if (selectedVideoVariantRelativeUri == trimmedLine && !trimmedLine.startsWith('#') && trimmedLine.endsWith('.m3u8')) {
          // This applies if the master manifest itself was selected as the main stream
          rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[trimmedLine]!));
        }
        // Add other non-stream/media related lines (e.g., #EXTM3U, #EXT-X-VERSION)
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

  /// Private helper to process a single variant (manifest + its segments) concurrently
  Future<void> _processSingleVariant(
      Uri masterHlsUri, // Used to resolve paths relative to the master manifest's original URL
      String originalRelativeUri,
      String absoluteVariantUrl,
      String hlsCacheDirPath,
      Map<String, String> localRewrittenManifestPaths,
      Function(int segmentsFound) onSegmentsCounted,
      Function(int downloadedSegments) onSegmentDownloaded,
      ) async {
    AppLogger.info('Starting concurrent processing for single variant: $absoluteVariantUrl', name: 'HlsCacheHandler');
    final Uri variantUri = Uri.parse(absoluteVariantUrl);
    final http.Response variantManifestResponse = await http.get(variantUri);
    if (variantManifestResponse.statusCode != 200) {
      AppLogger.error('Failed to download variant manifest $absoluteVariantUrl: HTTP ${variantManifestResponse.statusCode}. Skipping this variant.', name: 'HlsCacheHandler');
      onSegmentsCounted(0);
      return;
    }

    final String variantManifestContent = variantManifestResponse.body;
    final List<String> variantManifestLines = variantManifestContent.split('\n');

    final List<String> rewrittenVariantLines = [];
    final List<Future<void> Function()> segmentDownloadTasks = [];
    int segmentsInThisVariant = 0;

    for (final line in variantManifestLines) {
      final trimmedLine = line.trim();
      rewrittenVariantLines.add(line);

      if (!trimmedLine.startsWith('#') &&
          (trimmedLine.endsWith('.ts') || trimmedLine.endsWith('.mp4')) &&
          !trimmedLine.contains('.m3u8')) {

        segmentsInThisVariant++;

        final Uri segmentUri = _resolveUri(variantUri, trimmedLine);
        final String segmentFileName = p.basename(segmentUri.path);
        final String localSegmentPath = p.join(hlsCacheDirPath, segmentFileName);

        rewrittenVariantLines[rewrittenVariantLines.length - 1] = segmentFileName;

        segmentDownloadTasks.add(() => _downloadSegmentWithRetries(
          segmentUri,
          localSegmentPath,
              (downloadedBytes) {
            onSegmentDownloaded(1);
          },
        ));
      }
    }

    onSegmentsCounted(segmentsInThisVariant);

    // Process segment download tasks with a limited concurrency
    final List<Future<void>> activeSegmentTasks = [];
    final Queue<Future<void> Function()> segmentTaskQueue = Queue.from(segmentDownloadTasks);

    for (int i = 0; i < _maxConcurrentSegmentDownloads && segmentTaskQueue.isNotEmpty; i++) {
      activeSegmentTasks.add(segmentTaskQueue.removeFirst()());
    }

    Future<void> manageSegmentTasks() async {
      while (activeSegmentTasks.isNotEmpty) {
        final completed =  Future.any(activeSegmentTasks);
        activeSegmentTasks.remove(completed);
        if (segmentTaskQueue.isNotEmpty) {
          activeSegmentTasks.add(segmentTaskQueue.removeFirst()());
        }
      }
    }

    await manageSegmentTasks();

    // Save the rewritten variant manifest
    final String localVariantManifestFileName = p.basename(variantUri.path);
    final String localVariantManifestPath = p.join(hlsCacheDirPath, localVariantManifestFileName);
    final File localVariantManifestFile = File(localVariantManifestPath);
    await localVariantManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
    localRewrittenManifestPaths[originalRelativeUri] = localVariantManifestFile.path;
    AppLogger.info('Rewritten local variant manifest saved to: ${localVariantManifestFile.path}', name: 'HlsCacheHandler');
  }

  /// Private helper to download a single segment with retries
  Future<void> _downloadSegmentWithRetries(
      Uri segmentUri,
      String localSegmentPath,
      Function(int downloadedBytes) onProgressUpdate,
      ) async {
    bool segmentDownloadedSuccessfully = false;
    int retries = 0;
    while (!segmentDownloadedSuccessfully && retries < _maxSegmentRetries) {
      try {
        AppLogger.info('Downloading segment: $segmentUri (Attempt ${retries + 1}/${_maxSegmentRetries})', name: 'HlsCacheHandler');
        final http.Response segmentResponse = await http.get(segmentUri);
        if (segmentResponse.statusCode == 200) {
          final File segmentFile = File(localSegmentPath);
          await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
          onProgressUpdate(segmentResponse.bodyBytes.length);
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
        break;
      }
    }

    if (!segmentDownloadedSuccessfully) {
      AppLogger.error('Failed to download segment $segmentUri after $_maxSegmentRetries attempts. This segment will be missing.', name: 'HlsCacheHandler');
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
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
  static const int _maxConcurrentVariantDownloads = 3; // Limit for concurrent variant processing

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
      final RegExp mediaInfPattern = RegExp(r'^#EXT-X-MEDIA:.*URI="([^"]+)".*', multiLine: true);

      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String currentLine = masterManifestOriginalLines[i].trim();

        if (streamInfPattern.hasMatch(currentLine)) {
          if (i + 1 < masterManifestOriginalLines.length) {
            final String nextLine = masterManifestOriginalLines[i + 1].trim();
            if (!nextLine.startsWith('#') && nextLine.endsWith('.m3u8')) {
              final String absoluteUrl = _resolveUri(hlsUri, nextLine).toString();
              playlistUrisToDownload[nextLine] = absoluteUrl;
              AppLogger.info('Found variant playlist (stream-inf): $absoluteUrl', name: 'HlsCacheHandler');
            }
          }
        }
        else if (mediaInfPattern.firstMatch(currentLine) != null) {
          final Match mediaMatch = mediaInfPattern.firstMatch(currentLine)!;
          final String? uriInQuote = mediaMatch.group(1);
          if (uriInQuote != null && uriInQuote.endsWith('.m3u8')) {
            final String absoluteUrl = _resolveUri(hlsUri, uriInQuote).toString();
            playlistUrisToDownload[uriInQuote] = absoluteUrl;
            AppLogger.info('Found media playlist (media-inf): $absoluteUrl', name: 'HlsCacheHandler');
          }
        }
        else if (!currentLine.startsWith('#') && currentLine.endsWith('.m3u8')) {
          final String absoluteUrl = _resolveUri(hlsUri, currentLine).toString();
          if (!playlistUrisToDownload.containsKey(currentLine)) {
            playlistUrisToDownload[currentLine] = absoluteUrl;
            AppLogger.info('Found direct variant playlist (no EXT-X-STREAM-INF/MEDIA): $absoluteUrl', name: 'HlsCacheHandler');
          }
        }
      }

      if (playlistUrisToDownload.isEmpty) {
        AppLogger.warning('No explicit variant HLS playlists found in master manifest. Attempting to treat master as direct segment list.', name: 'HlsCacheHandler');
        playlistUrisToDownload[p.basename(hlsUri.path)] = hlsUrl;
      }

      // Map: original_relative_uri_from_master -> local_file_path_of_rewritten_variant_manifest
      final Map<String, String> localRewrittenManifestPaths = {};

      // Initialize progress tracking
      int totalSegmentsOverall = 0;
      int downloadedSegmentsOverall = 0;

      // This Completer will signal when all segment counts are known
      final Completer<void> segmentCountDiscoveryCompleter = Completer<void>();
      int variantsToProcessCount = playlistUrisToDownload.length;
      int variantsProcessedForCount = 0;

      // 3. Process All Identified Variant/Media Playlists Concurrently
      // Each future in this list will handle downloading a variant manifest,
      // discovering its segments, downloading segments concurrently, and rewriting the variant manifest.
      final List<Future<void>> variantProcessingTasks = [];
      final Queue<Future<void> Function()> variantTaskQueue = Queue();

      for (final MapEntry<String, String> entry in playlistUrisToDownload.entries) {
        final String originalRelativeUri = entry.key;
        final String absoluteVariantUrl = entry.value;

        // Add each variant processing task to a queue
        variantTaskQueue.add(() => _processSingleVariant(
          hlsUri, // Pass master HLS URI for correct path resolution if needed
          originalRelativeUri,
          absoluteVariantUrl,
          hlsCacheDirPath,
          localRewrittenManifestPaths,
              (segmentsFound) {
            // This callback updates the totalSegmentsOverall
            // It must be thread-safe as it's called concurrently
            totalSegmentsOverall += segmentsFound;
            variantsProcessedForCount++;
            if (variantsProcessedForCount == variantsToProcessCount) {
              // All variants have reported their segment counts
              segmentCountDiscoveryCompleter.complete();
            }
          },
              (downloaded) {
            // This callback updates downloadedSegmentsOverall and reports progress
            // It must be thread-safe as it's called concurrently
            downloadedSegmentsOverall += downloaded;
            onProgress?.call(downloadedSegmentsOverall, totalSegmentsOverall);
          },
        ));
      }

      // Start processing variant tasks with a limited concurrency
      final List<Future<void>> activeVariantTasks = [];
      for (int i = 0; i < _maxConcurrentVariantDownloads && variantTaskQueue.isNotEmpty; i++) {
        activeVariantTasks.add(variantTaskQueue.removeFirst()());
      }

      // As tasks complete, add new ones from the queue
      Future<void> manageVariantTasks() async {
        while (activeVariantTasks.isNotEmpty) {
          final completed =  Future.any(activeVariantTasks);
          activeVariantTasks.remove(completed);
          if (variantTaskQueue.isNotEmpty) {
            activeVariantTasks.add(variantTaskQueue.removeFirst()());
          }
        }
      }

      // Run task manager and wait for all variants to finish processing
      await Future.wait([
        manageVariantTasks(),
        segmentCountDiscoveryCompleter.future, // Wait for all segment counts to be discovered
      ]);
      await Future.wait(activeVariantTasks); // Ensure all initial tasks are complete


      AppLogger.info('Overall: Found $totalSegmentsOverall segments. Downloaded $downloadedSegmentsOverall.', name: 'HlsCacheHandler');

      // 5. Rewrite Local Master Manifest to point to *all* local variant/media manifests
      final String localMasterManifestFileName = p.basename(hlsUri.path);
      final String localMasterManifestPath = p.join(hlsCacheDirPath, localMasterManifestFileName);
      final File localMasterManifestFile = File(localMasterManifestPath);

      final List<String> rewrittenMasterLines = [];
      for (int i = 0; i < masterManifestOriginalLines.length; i++) {
        final String originalLine = masterManifestOriginalLines[i];
        final String trimmedLine = originalLine.trim();

        bool lineHandled = false;

        if (streamInfPattern.hasMatch(trimmedLine) && i + 1 < masterManifestOriginalLines.length) {
          final String nextLineOriginalUri = masterManifestOriginalLines[i + 1].trim();
          if (!nextLineOriginalUri.startsWith('#') && nextLineOriginalUri.endsWith('.m3u8')) {
            if (localRewrittenManifestPaths.containsKey(nextLineOriginalUri)) {
              rewrittenMasterLines.add(originalLine);
              rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[nextLineOriginalUri]!));
              i++;
              lineHandled = true;
            }
          }
        }
        else if (mediaInfPattern.firstMatch(trimmedLine) != null) {
          final Match mediaMatch = mediaInfPattern.firstMatch(trimmedLine)!;
          final String? uriInQuote = mediaMatch.group(1);
          if (uriInQuote != null && uriInQuote.endsWith('.m3u8')) {
            if (localRewrittenManifestPaths.containsKey(uriInQuote)) {
              final String localFilename = p.basename(localRewrittenManifestPaths[uriInQuote]!);
              rewrittenMasterLines.add(trimmedLine.replaceAll('URI="$uriInQuote"', 'URI="$localFilename"'));
              lineHandled = true;
            }
          }
        }
        else if (!lineHandled && !trimmedLine.startsWith('#') && trimmedLine.endsWith('.m3u8')) {
          if (localRewrittenManifestPaths.containsKey(trimmedLine)) {
            rewrittenMasterLines.add(p.basename(localRewrittenManifestPaths[trimmedLine]!));
            lineHandled = true;
          }
        }

        if (!lineHandled) {
          rewrittenMasterLines.add(originalLine);
        }
      }

      await localMasterManifestFile.writeAsString(rewrittenMasterLines.join('\n'));
      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

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

  /// New private helper to process a single variant concurrently
  /// Returns the number of segments found in this variant.
  Future<void> _processSingleVariant(
      Uri masterHlsUri, // Added to resolve segments if variantUri is relative
      String originalRelativeUri,
      String absoluteVariantUrl,
      String hlsCacheDirPath,
      Map<String, String> localRewrittenManifestPaths,
      Function(int segmentsFound) onSegmentsCounted,
      Function(int downloadedSegments) onSegmentDownloaded,
      ) async {
    AppLogger.info('Starting concurrent processing for variant: $absoluteVariantUrl', name: 'HlsCacheHandler');
    final Uri variantUri = Uri.parse(absoluteVariantUrl);
    final http.Response variantManifestResponse = await http.get(variantUri);
    if (variantManifestResponse.statusCode != 200) {
      AppLogger.error('Failed to download variant manifest $absoluteVariantUrl: HTTP ${variantManifestResponse.statusCode}. Skipping this variant.', name: 'HlsCacheHandler');
      onSegmentsCounted(0); // Report 0 segments if manifest failed
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
            onSegmentDownloaded(1); // Report 1 segment downloaded
          },
        ));
      }
    }

    onSegmentsCounted(segmentsInThisVariant); // Report total segments found in this variant

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

    await manageSegmentTasks(); // Wait for all segments in this variant to complete

    // Save the rewritten variant manifest
    final String localVariantManifestFileName = p.basename(variantUri.path);
    final String localVariantManifestPath = p.join(hlsCacheDirPath, localVariantManifestFileName);
    final File localVariantManifestFile = File(localVariantManifestPath);
    await localVariantManifestFile.writeAsString(rewrittenVariantLines.join('\n'));
    localRewrittenManifestPaths[originalRelativeUri] = localVariantManifestFile.path;
    AppLogger.info('Rewritten local variant manifest saved to: ${localVariantManifestFile.path}', name: 'HlsCacheHandler');
  }

  /// New private helper to download a single segment with retries
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
          onProgressUpdate(segmentResponse.bodyBytes.length); // Report actual bytes or just a count of 1 segment
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
        break; // For other unexpected errors, don't retry
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
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'dart:convert';

// class HlsCacheHandler {
//   static const int _maxSegmentRetries = 3;
//   static const Duration _retryDelay = Duration(seconds: 2);
//
//   final LocalProxyServer _proxyServer; // Add this line
//
//   // Modify the constructor to accept LocalProxyServer
//   HlsCacheHandler({required LocalProxyServer proxyServer}) : _proxyServer = proxyServer;
//
//   /// Caches an HLS stream, downloading a single chosen variant and its segments sequentially.
//   /// Returns the local path to the rewritten master manifest.
//   ///
//   /// By default, it attempts to select the smallest bandwidth video variant
//   /// and its associated audio track.
//   Future<String?> cacheHls(
//       String hlsUrl,
//       String cacheBaseDirPath,
//       String trackId, {
//         Function(int received, int total)? onProgress,
//         bool encrypt = false, // Add encrypt parameter here
//       }) async {
//     AppLogger.info('Attempting to cache SINGLE HLS variant sequentially: $hlsUrl for track $trackId', name: 'HlsCacheHandler');
//
//     final Uri hlsUri = Uri.parse(hlsUrl);
//     final String hlsCacheDirPath = p.join(cacheBaseDirPath, trackId);
//     final Directory hlsCacheDir = Directory(hlsCacheDirPath);
//
//     try {
//       if (!await hlsCacheDir.exists()) {
//         await hlsCacheDir.create(recursive: true);
//         AppLogger.info('Created HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
//       }
//
//       // 1. Download Master Manifest
//       AppLogger.info('Downloading master manifest from $hlsUrl', name: 'HlsCacheHandler');
//       final http.Response masterManifestResponse = await http.get(hlsUri);
//       if (masterManifestResponse.statusCode != 200) {
//         AppLogger.error('Failed to download master manifest: ${masterManifestResponse.statusCode}', name: 'HlsCacheHandler');
//         throw Exception('Failed to download master manifest');
//       }
//
//       String masterManifestContent = masterManifestResponse.body;
//       Uri baseUri = hlsUri; // Base URI for resolving relative paths in manifest
//
//       // Parse master manifest to find variants
//       List<String> mediaPlaylistUrls = [];
//       List<String> lines = masterManifestContent.split('\n');
//       for (int i = 0; i < lines.length; i++) {
//         String line = lines[i].trim();
//         if (line.startsWith('#EXT-X-STREAM-INF')) {
//           // This line describes a variant stream
//           // Find the URI on the next line
//           if (i + 1 < lines.length) {
//             String uriLine = lines[i + 1].trim();
//             if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
//               mediaPlaylistUrls.add(uriLine);
//             }
//           }
//         }
//       }
//
//       if (mediaPlaylistUrls.isEmpty) {
//         // If no stream-inf found, assume it's a media playlist directly (single variant)
//         AppLogger.info('No EXT-X-STREAM-INF found, assuming single media playlist.', name: 'HlsCacheHandler');
//         mediaPlaylistUrls.add(hlsUrl); // Treat the original URL as the media playlist
//       }
//
//       String? selectedMediaPlaylistUrl;
//       // For simplicity, select the first media playlist found
//       if (mediaPlaylistUrls.isNotEmpty) {
//         selectedMediaPlaylistUrl = _resolveUri(baseUri, mediaPlaylistUrls.first).toString();
//         AppLogger.info('Selected media playlist: $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
//       } else {
//         AppLogger.error('No media playlists found in master manifest.', name: 'HlsCacheHandler');
//         throw Exception('No media playlists found');
//       }
//
//       // 2. Download Media Playlist (the chosen variant's playlist)
//       AppLogger.info('Downloading media playlist from $selectedMediaPlaylistUrl', name: 'HlsCacheHandler');
//       final http.Response mediaPlaylistResponse = await http.get(Uri.parse(selectedMediaPlaylistUrl));
//       if (mediaPlaylistResponse.statusCode != 200) {
//         AppLogger.error('Failed to download media playlist: ${mediaPlaylistResponse.statusCode}', name: 'HlsCacheHandler');
//         throw Exception('Failed to download media playlist');
//       }
//
//       String mediaPlaylistContent = mediaPlaylistResponse.body;
//       Uri mediaPlaylistBaseUri = Uri.parse(selectedMediaPlaylistUrl); // Base URI for resolving segments
//
//       // 3. Download Segments sequentially and prepare to rewrite media playlist
//       List<String> segmentUrls = [];
//       List<String> mediaPlaylistLines = mediaPlaylistContent.split('\n');
//       for (String line in mediaPlaylistLines) {
//         String trimmedLine = line.trim();
//         if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
//           // This is a segment URI
//           segmentUrls.add(_resolveUri(mediaPlaylistBaseUri, trimmedLine).toString());
//         }
//       }
//
//       int totalSegments = segmentUrls.length;
//       int downloadedSegments = 0;
//
//       // Track progress for segments
//       if (onProgress != null) {
//         // We can't know total bytes for all segments upfront,
//         // so we'll report progress based on segment count
//         onProgress(0, totalSegments);
//       }
//
//
//       for (String segmentUrl in segmentUrls) {
//         AppLogger.info('Downloading segment: $segmentUrl', name: 'HlsCacheHandler');
//         final Uri segmentUri = Uri.parse(segmentUrl);
//
//         // This is crucial: Construct the local path to preserve original directory structure
//         // Get the path relative to the media playlist's base URI
//         final String relativeSegmentPath = mediaPlaylistBaseUri.path.isEmpty
//             ? p.basename(segmentUri.path) // If base is root, just take filename
//             : p.relative(segmentUri.path, from: mediaPlaylistBaseUri.path.substring(0, mediaPlaylistBaseUri.path.lastIndexOf('/') + 1));
//
//         final File segmentFile = File(p.join(hlsCacheDirPath, relativeSegmentPath)); // Save with original relative path structure
//
//         // Ensure segment directory exists if it's nested
//         if (!await segmentFile.parent.exists()) {
//           await segmentFile.parent.create(recursive: true);
//         }
//
//         bool segmentDownloaded = false;
//         for (int retry = 0; retry < _maxSegmentRetries; retry++) {
//           try {
//             final http.Response segmentResponse = await http.get(segmentUri);
//             if (segmentResponse.statusCode == 200) {
//               Uint8List segmentBytes = segmentResponse.bodyBytes;
//
//               if (encrypt) {
//                 AppLogger.info('Encrypting HLS segment: ${segmentFile.path} for track $trackId', name: 'HlsCacheHandler'); // Log full path for clarity
//                 segmentBytes = AESHelper.encrypt(segmentBytes); // Encrypt segment bytes
//               }
//
//               await segmentFile.writeAsBytes(segmentBytes);
//               AppLogger.info('Saved segment: ${segmentFile.path}', name: 'HlsCacheHandler');
//               segmentDownloaded = true;
//               break; // Segment downloaded successfully
//             } else {
//               AppLogger.warning('Failed to download segment ${segmentFile.path}: ${segmentResponse.statusCode}. Retrying...', name: 'HlsCacheHandler');
//             }
//           } catch (e, st) {
//             AppLogger.error('Error downloading segment ${segmentFile.path}: $e. Retrying...', error: e, stackTrace: st, name: 'HlsCacheHandler');
//           }
//           await Future.delayed(_retryDelay);
//         }
//
//         if (!segmentDownloaded) {
//           AppLogger.error('Failed to download segment after $_maxSegmentRetries retries: $segmentUrl', name: 'HlsCacheHandler');
//           throw Exception('Failed to download segment: $segmentUrl');
//         }
//
//         // Increment progress for each successful segment download
//         downloadedSegments++;
//         if (onProgress != null) {
//           onProgress(downloadedSegments, totalSegments);
//         }
//       }
//
//       // --- CRITICAL CORRECTION STARTS HERE ---
//
//       // 4. Rewrite Media Playlist (segments) to point to local relative paths
//       String finalMediaPlaylistContent = '';
//       for (String line in mediaPlaylistLines) {
//         String trimmedLine = line.trim();
//         if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#') && !trimmedLine.startsWith('#EXT')) { // Ensure it's a URI and not an HLS tag
//           // This is a segment URI, replace with its local relative path
//           final Uri segmentUri = _resolveUri(mediaPlaylistBaseUri, trimmedLine);
//           // Get the path relative to the media playlist's base URI
//           final String relativeSegmentPath = mediaPlaylistBaseUri.path.isEmpty
//               ? p.basename(segmentUri.path)
//               : p.relative(segmentUri.path, from: mediaPlaylistBaseUri.path.substring(0, mediaPlaylistBaseUri.path.lastIndexOf('/') + 1));
//
//           finalMediaPlaylistContent += '$relativeSegmentPath\n'; // Store local relative path
//           AppLogger.info('Rewrote media playlist segment line: $trimmedLine to $relativeSegmentPath', name: 'HlsCacheHandler');
//         } else {
//           finalMediaPlaylistContent += '$line\n'; // Keep other lines as is
//         }
//       }
//
//       // Save the rewritten media playlist locally
//       final String localMediaPlaylistFileName = p.basename(Uri.parse(selectedMediaPlaylistUrl).path);
//       final File localMediaPlaylistFile = File(p.join(hlsCacheDirPath, localMediaPlaylistFileName));
//       await localMediaPlaylistFile.writeAsString(finalMediaPlaylistContent);
//       AppLogger.info('Rewritten HLS media playlist saved to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');
//
//
//       // 5. Rewrite Master Manifest: Only if needed, to point to local relative paths of media playlists.
//       // Usually, master manifests contain relative paths anyway, but if they were absolute,
//       // we'd convert them to relative paths based on the hlsCacheDirPath.
//       // For simplicity, we'll assume they are relative and copy as is or ensure correct relative path.
//       // The _proxyServer.getHlsManifestProxyUrl call and replacement is removed.
//       String finalMasterManifestContent = '';
//       for (String line in masterManifestContent.split('\n')) {
//         String trimmedLine = line.trim();
//         if (trimmedLine.startsWith('#EXT-X-STREAM-INF')) {
//           finalMasterManifestContent += line + '\n'; // Keep the stream-info line
//           // The next line contains the media playlist URI
//           int streamInfIndex = masterManifestContent.split('\n').indexOf(line);
//           if (streamInfIndex + 1 < masterManifestContent.split('\n').length) {
//             String uriLine = masterManifestContent.split('\n')[streamInfIndex + 1].trim();
//             if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
//               // Resolve the URI to an absolute one from the original base
//               Uri resolvedUri = _resolveUri(baseUri, uriLine);
//               // Get the path relative to the master manifest's location (which is hlsCacheDirPath)
//               String relativePathToMediaPlaylist = p.relative(resolvedUri.path, from: baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1));
//               finalMasterManifestContent += '$relativePathToMediaPlaylist\n'; // Store local relative path
//               AppLogger.info('Rewrote master manifest media playlist line: $uriLine to $relativePathToMediaPlaylist', name: 'HlsCacheHandler');
//             }
//           }
//         } else {
//           finalMasterManifestContent += line + '\n'; // Keep other lines as is
//         }
//       }
//
//       // Save the rewritten master manifest locally
//       final String localMasterManifestFileName = p.basename(hlsUri.path);
//       final File localMasterManifestFile = File(p.join(hlsCacheDirPath, localMasterManifestFileName));
//       await localMasterManifestFile.writeAsString(finalMasterManifestContent); // Save the corrected content
//       AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
//
//       AppLogger.info('HLS caching complete for track $trackId. Local master manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
//       // Return the local path to the rewritten master manifest file
//       return localMasterManifestFile.path;
//
//     } catch (e, st) {
//       AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
//       if (await hlsCacheDir.exists()) {
//         AppLogger.info('Cleaning up partial HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
//         await hlsCacheDir.delete(recursive: true);
//       }
//       return null;
//     }
//   }
//
//   /// Helper to resolve relative URIs against a base URI.
//   Uri _resolveUri(Uri baseUri, String relativePath) {
//     if (Uri.parse(relativePath).isAbsolute) {
//       return Uri.parse(relativePath);
//     }
//     // Use resolve for better URI handling, it handles '..' and other URI specifics
//     return baseUri.resolve(relativePath);
//   }
//
//   /// Deletes a cached HLS stream directory.
//   Future<void> deleteCachedHls(String hlsLocalDirPath) async {
//     final Directory hlsDir = Directory(hlsLocalDirPath);
//     if (await hlsDir.exists()) {
//       AppLogger.info('Deleting HLS cache directory: ${hlsDir.path}', name: 'HlsCacheHandler');
//       await hlsDir.delete(recursive: true);
//     }
//   }
// }

class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  final LocalProxyServer _proxyServer;

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
        bool encrypt = false,
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

      // 3. Download Segments sequentially and prepare to rewrite media playlist
      List<String> segmentUrls = [];
      List<String> mediaPlaylistLines = mediaPlaylistContent.split('\n');
      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) {
          // This is a segment URI
          segmentUrls.add(_resolveUri(mediaPlaylistBaseUri, trimmedLine).toString());
        }
      }

      int totalSegments = segmentUrls.length;
      int downloadedSegments = 0;

      // Track progress for segments
      if (onProgress != null) {
        // We can't know total bytes for all segments upfront,
        // so we'll report progress based on segment count
        onProgress(0, totalSegments);
      }


      for (String segmentUrl in segmentUrls) {
        AppLogger.info('Downloading segment: $segmentUrl', name: 'HlsCacheHandler');
        final Uri segmentUri = Uri.parse(segmentUrl);

        // This is the new naming convention
        final String segmentFileName = '${trackId}_${p.basename(segmentUri.path)}';
        final String segmentPath = p.join(hlsCacheDirPath, segmentFileName);
        final File segmentFile = File(segmentPath);


        final http.Response segmentResponse = await http.get(segmentUri);
        if (segmentResponse.statusCode != 200) {
          AppLogger.error('Failed to download segment $segmentUrl: ${segmentResponse.statusCode}', name: 'HlsCacheHandler');
          continue; // Skip to next segment, but in production, add retries
        }

        Uint8List segmentBytes = segmentResponse.bodyBytes;
        if (encrypt) {
          segmentBytes = AESHelper.encrypt(segmentBytes);
        }
        await segmentFile.writeAsBytes(segmentBytes);
        downloadedSegments++;
        if (onProgress != null) {
          onProgress(downloadedSegments, totalSegments);
        }
      }

      // --- CRITICAL CORRECTION STARTS HERE ---

      // 4. Rewrite Media Playlist (segments) to point to local relative paths
      String finalMediaPlaylistContent = '';
      for (String line in mediaPlaylistLines) {
        String trimmedLine = line.trim();
        if (trimmedLine.startsWith('#EXTINF')) {
          // Parse and normalize duration to integer if it's a float ending in .0
          final parts = trimmedLine.split(':');
          if (parts.length > 1) {
            final durationStr = parts[1].split(',').first.trim();
            double? duration = double.tryParse(durationStr);
            if (duration != null) {
              if (duration == duration.floorToDouble()) {
                final int intDuration = duration.toInt();
                final rebuiltLine = '${parts[0]}:$intDuration,${parts[1].split(',').skip(1).join(',')}';
                finalMediaPlaylistContent += '$rebuiltLine\n';
                AppLogger.info('Normalized #EXTINF duration from $durationStr to $intDuration for iOS compatibility', name: 'HlsCacheHandler');
                continue;
              }
            }
          }
          finalMediaPlaylistContent += '$line\n'; // Keep as is if not normalizable
        } else if (trimmedLine.isNotEmpty && !trimmedLine.startsWith('#')) { // Segment URI
          final Uri segmentUri = _resolveUri(mediaPlaylistBaseUri, trimmedLine);
          final String relativeSegmentPath = '${trackId}_${p.basename(segmentUri.path)}';

          finalMediaPlaylistContent += '$relativeSegmentPath\n'; // Store local relative path
          AppLogger.info('Rewrote media playlist segment line: $trimmedLine to $relativeSegmentPath', name: 'HlsCacheHandler');
        } else {
          finalMediaPlaylistContent += '$line\n'; // Keep other lines as is
        }
      }

      // Save the rewritten media playlist locally
      final String localMediaPlaylistFileName = p.basename(Uri.parse(selectedMediaPlaylistUrl).path);
      final File localMediaPlaylistFile = File(p.join(hlsCacheDirPath, localMediaPlaylistFileName));
      await localMediaPlaylistFile.writeAsString(finalMediaPlaylistContent);
      AppLogger.info('Rewritten HLS media playlist saved to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');


      // 5. Rewrite Master Manifest: Only if needed, to point to local relative paths of media playlists.
      // Usually, master manifests contain relative paths anyway, but if they were absolute,
      // we'd convert them to relative paths based on the hlsCacheDirPath.
      // For simplicity, we'll assume they are relative and copy as is or ensure correct relative path.
      // The _proxyServer.getHlsManifestProxyUrl call and replacement is removed.
      String finalMasterManifestContent = '';
      for (String line in masterManifestContent.split('\n')) {
        String trimmedLine = line.trim();
        if (trimmedLine.startsWith('#EXT-X-STREAM-INF')) {
          finalMasterManifestContent += line + '\n'; // Keep the stream-info line
          // The next line contains the media playlist URI
          int streamInfIndex = masterManifestContent.split('\n').indexOf(line);
          if (streamInfIndex + 1 < masterManifestContent.split('\n').length) {
            String uriLine = masterManifestContent.split('\n')[streamInfIndex + 1].trim();
            if (uriLine.isNotEmpty && !uriLine.startsWith('#')) {
              // Resolve the URI to an absolute one from the original base
              Uri resolvedUri = _resolveUri(baseUri, uriLine);
              // Get the path relative to the master manifest's location (which is hlsCacheDirPath)
              String relativePathToMediaPlaylist = p.relative(resolvedUri.path, from: baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1));
              finalMasterManifestContent += '$relativePathToMediaPlaylist\n'; // Store local relative path
              AppLogger.info('Rewrote master manifest media playlist line: $uriLine to $relativePathToMediaPlaylist', name: 'HlsCacheHandler');
            }
          }
        } else {
          finalMasterManifestContent += line + '\n'; // Keep other lines as is
        }
      }

      // Save the rewritten master manifest locally
      final String localMasterManifestFileName = p.basename(hlsUri.path);
      final File localMasterManifestFile = File(p.join(hlsCacheDirPath, localMasterManifestFileName));
      await localMasterManifestFile.writeAsString(finalMasterManifestContent); // Save the corrected content
      AppLogger.info('Rewritten HLS master manifest saved to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      AppLogger.info('HLS caching complete for track $trackId. Local master manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
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
    // Use resolve for better URI handling, it handles '..' and other URI specifics
    return baseUri.resolve(relativePath);
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
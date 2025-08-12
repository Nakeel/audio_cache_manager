import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';

class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  final http.Client _httpClient;
  final LocalProxyServer _proxyServer;
  final CacheMetadataStore _metadataStore;

  HlsCacheHandler({
    required LocalProxyServer proxyServer,
    required CacheMetadataStore metadataStore,
    http.Client? httpClient,
  })  : _proxyServer = proxyServer,
        _metadataStore = metadataStore,
        _httpClient = httpClient ?? http.Client();

  /// Caches an HLS stream, downloading a single chosen variant and its segments sequentially.
  /// Returns a [CacheEntry] for the cached HLS stream.
  Future<CacheEntry?> cacheHls({
    required String hlsUrl,
    required String cacheBaseDirPath,
    required String trackId,
    bool encrypt = false,
  }) async {
    AppLogger.info('Attempting to cache HLS stream: $hlsUrl for track $trackId', name: 'HlsCacheHandler');

    final Uri hlsUri = Uri.parse(hlsUrl);
    final String hlsCacheDirPath = p.join(cacheBaseDirPath, 'hls_$trackId');
    final Directory hlsCacheDir = Directory(hlsCacheDirPath);

    try {
      if (!await hlsCacheDir.exists()) {
        await hlsCacheDir.create(recursive: true);
        AppLogger.info('Created HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
      }

      // Download the master manifest
      final http.Response masterManifestResponse = await _httpClient.get(hlsUri);
      if (masterManifestResponse.statusCode != 200) {
        AppLogger.error('Failed to download HLS master manifest from $hlsUrl. Status code: ${masterManifestResponse.statusCode}', name: 'HlsCacheHandler');
        return null;
      }
      AppLogger.info('Downloaded HLS master manifest successfully.', name: 'HlsCacheHandler');

      final String masterManifestFileName = p.basename(hlsUri.path);
      final File localMasterManifestFile = File(p.join(hlsCacheDir.path, masterManifestFileName));

      // Rewrite the master manifest to point to local paths
      String rewrittenMasterManifestContent = _rewriteHlsManifestForLocalSaving(
          masterManifestResponse.body,
          hlsUri,
          hlsCacheDir.path
      );
      await localMasterManifestFile.writeAsString(rewrittenMasterManifestContent);
      AppLogger.info('Saved rewritten HLS master manifest to: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');

      // The manifest is now local, so read it back to parse sub-manifests
      final RegExp mediaPlaylistPattern = RegExp(r'^[^#].*\.m3u8$', multiLine: true);
      final Iterable<RegExpMatch> mediaPlaylistMatches = mediaPlaylistPattern.allMatches(rewrittenMasterManifestContent);

      if (mediaPlaylistMatches.isEmpty) {
        AppLogger.warning('No media playlists found in master manifest. HLS caching may be incomplete.', name: 'HlsCacheHandler');
      }

      // Download all media playlists and their segments
      for (final match in mediaPlaylistMatches) {
        final String mediaPlaylistPath = match.group(0)!;
        final Uri mediaPlaylistUri = hlsUri.resolve(mediaPlaylistPath);

        AppLogger.info('Downloading media playlist: $mediaPlaylistUri', name: 'HlsCacheHandler');

        final http.Response mediaPlaylistResponse = await _httpClient.get(mediaPlaylistUri);
        if (mediaPlaylistResponse.statusCode != 200) {
          AppLogger.error('Failed to download media playlist: $mediaPlaylistUri', name: 'HlsCacheHandler');
          continue;
        }

        final String mediaPlaylistFileName = p.basename(mediaPlaylistUri.path);
        final File localMediaPlaylistFile = File(p.join(hlsCacheDir.path, mediaPlaylistFileName));

        // Rewrite the media playlist to point to local segment/key files
        String rewrittenMediaPlaylistContent = _rewriteHlsManifestForLocalSaving(
            mediaPlaylistResponse.body,
            mediaPlaylistUri,
            hlsCacheDir.path
        );
        await localMediaPlaylistFile.writeAsString(rewrittenMediaPlaylistContent);
        AppLogger.info('Saved rewritten media playlist to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');

        // Now, download all the segments and keys from this media playlist
        await _downloadSegmentsAndKeys(
          manifestContent: rewrittenMediaPlaylistContent,
          baseUri: mediaPlaylistUri,
          localPath: hlsCacheDir.path,
          encrypt: encrypt,
        );
      }

      // Create and save the CacheEntry
      final CacheEntry cacheEntry = CacheEntry(
        trackId: trackId,
        originalUrl: hlsUrl,
        filePath: '', // Not used for HLS
        timestamp: DateTime.now(),
        fileSize: 0, // Placeholder, size is calculated on demand
        isEncrypted: encrypt,
        etag: '', lastModified: '', contentType: '',
        proxyUrl: _proxyServer.getProxyUrl(trackId, isHls: true),
        isHls: true,
        hlsLocalPath: hlsCacheDir.path,
        hlsManifestFilePath: localMasterManifestFile.path,
      );
      await _metadataStore.save(cacheEntry);

      AppLogger.info('HLS caching complete for track $trackId. Local manifest: ${localMasterManifestFile.path}', name: 'HlsCacheHandler');
      return cacheEntry;

    } catch (e, st) {
      AppLogger.error('Error caching HLS stream $hlsUrl: $e', error: e, stackTrace: st, name: 'HlsCacheHandler');
      if (await hlsCacheDir.exists()) {
        AppLogger.info('Cleaning up partial HLS cache directory: ${hlsCacheDir.path}', name: 'HlsCacheHandler');
        await hlsCacheDir.delete(recursive: true);
      }
      return null;
    }
  }

  /// Downloads all segments and keys referenced in a manifest.
  Future<void> _downloadSegmentsAndKeys({
    required String manifestContent,
    required Uri baseUri,
    required String localPath,
    required bool encrypt,
  }) async {
    final RegExp keyPattern = RegExp(r'#EXT-X-KEY:METHOD=AES-128,URI="(.*)"');
    final Iterable<RegExpMatch> keyMatches = keyPattern.allMatches(manifestContent);
    if (keyMatches.isNotEmpty) {
      final String keyUrl = _resolveUri(baseUri, keyMatches.first.group(1)!).toString();
      AppLogger.info('Downloading HLS key from: $keyUrl', name: 'HlsCacheHandler');
      await _downloadAndSaveFile(keyUrl, localPath, encrypt);
    }

    final RegExp segmentPattern = RegExp(r'^(?!#).*\.ts$', multiLine: true);
    final Iterable<RegExpMatch> segmentMatches = segmentPattern.allMatches(manifestContent);
    for (final match in segmentMatches) {
      final String segmentUrl = _resolveUri(baseUri, match.group(0)!).toString();
      AppLogger.info('Downloading HLS segment: $segmentUrl', name: 'HlsCacheHandler');
      await _downloadAndSaveFile(segmentUrl, localPath, encrypt);
    }
  }

  /// Helper to download and optionally encrypt a file.
  Future<void> _downloadAndSaveFile(String url, String localPath, bool encrypt) async {
    final String fileName = p.basename(Uri.parse(url).path);
    final File localFile = File(p.join(localPath, fileName));

    if (await localFile.exists()) {
      AppLogger.info('File already exists locally: ${localFile.path}', name: 'HlsCacheHandler');
      return;
    }

    final http.Response response = await _httpClient.get(Uri.parse(url));
    if (response.statusCode != 200) {
      AppLogger.error('Failed to download file from $url: ${response.statusCode}', name: 'HlsCacheHandler');
      return;
    }

    Uint8List fileBytes = response.bodyBytes;
    if (encrypt) {
      fileBytes = AESHelper.encrypt(fileBytes);
    }
    await localFile.writeAsBytes(fileBytes);
    AppLogger.info('Saved file to ${localFile.path} (size: ${fileBytes.length} bytes, encrypted: $encrypt)', name: 'HlsCacheHandler');
  }

  /// Rewrites manifest content to use local file names instead of remote URLs.
  String _rewriteHlsManifestForLocalSaving(String manifestContent, Uri baseUri, String localPath) {
    String rewrittenContent = manifestContent;

    // Rewrite #EXT-X-KEY URI
    final keyPattern = RegExp(r'(#EXT-X-KEY:METHOD=AES-128,URI=")(.*?)(".*)');
    rewrittenContent = rewrittenContent.replaceAllMapped(keyPattern, (match) {
      final String originalUrl = match.group(2)!;
      final Uri resolvedUri = _resolveUri(baseUri, originalUrl);
      return '${match.group(1)}${p.basename(resolvedUri.path)}${match.group(3)}';
    });

    // Rewrite segment and sub-manifest URIs
    final urlPattern = RegExp(r'^(?!#)(.*\.ts|.*\.m3u8)$', multiLine: true);
    rewrittenContent = rewrittenContent.replaceAllMapped(urlPattern, (match) {
      final String originalUrl = match.group(1)!;
      final Uri resolvedUri = _resolveUri(baseUri, originalUrl);
      return p.basename(resolvedUri.path);
    });

    return rewrittenContent;
  }

  /// Helper to resolve relative URIs against a base URI.
  Uri _resolveUri(Uri baseUri, String relativePath) {
    if (Uri.parse(relativePath).isAbsolute) {
      return Uri.parse(relativePath);
    }
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

//
// import 'dart:io';
// import 'dart:typed_data' show Uint8List;
// import 'package:audio_cache_manager/utils/aes_encryptor.dart';
// import 'package:audio_cache_manager/utils/app_logger.dart';
// import 'package:http/http.dart' as http;
// import 'package:path/path.dart' as p;
// import 'dart:async';
// import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
//
// class HlsCacheHandler {
//   static const int _maxSegmentRetries = 3;
//   static const Duration _retryDelay = Duration(seconds: 2);
//
//   final LocalProxyServer _proxyServer;
//
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
//         bool encrypt = false,
//       }) async {
//     AppLogger.info('Attempting to cache SINGLE HLS variant sequentially: $hlsUrl for track $trackId', name: 'HlsCacheHandler');
//
//     final Uri hlsUri = Uri.parse(hlsUrl);
//     final String hlsCacheDirPath = p.join(cacheBaseDirPath, trackId);
//     final Directory hlsCacheDir = Directory(hlsCacheDirPath);
//
//     try {
//       // Create the directory if it doesn't exist
//       if (!await hlsCacheDir.exists()) {
//         await hlsCacheDir.create(recursive: true);
//       }
//
//       // 1. Download the master manifest
//       AppLogger.info('Downloading master manifest from: $hlsUrl', name: 'HlsCacheHandler');
//       final http.Response masterManifestResponse = await http.get(hlsUri);
//       if (masterManifestResponse.statusCode != 200) {
//         throw http.ClientException('Failed to download master manifest from $hlsUrl with status code ${masterManifestResponse.statusCode}');
//       }
//       String masterManifestContent = String.fromCharCodes(masterManifestResponse.bodyBytes);
//
//       // 2. Choose the media playlist (e.g., lowest bandwidth) and download it
//       final mediaPlaylistUrl = _chooseVariant(masterManifestContent, hlsUri);
//       if (mediaPlaylistUrl == null) {
//         throw Exception('Could not find a suitable media playlist in the master manifest.');
//       }
//       AppLogger.info('Selected media playlist: $mediaPlaylistUrl', name: 'HlsCacheHandler');
//
//       final http.Response mediaPlaylistResponse = await http.get(Uri.parse(mediaPlaylistUrl));
//       if (mediaPlaylistResponse.statusCode != 200) {
//         throw http.ClientException('Failed to download media playlist from $mediaPlaylistUrl');
//       }
//       String mediaPlaylistContent = String.fromCharCodes(mediaPlaylistResponse.bodyBytes);
//
//       // 3. Parse segments and download them
//       final segments = _parseSegments(mediaPlaylistContent);
//       final int totalSegments = segments.length;
//       int downloadedSegments = 0;
//
//       AppLogger.info('Total segments to download: $totalSegments', name: 'HlsCacheHandler');
//
//       for (final segment in segments) {
//         final segmentUrl = _resolveUri(Uri.parse(mediaPlaylistUrl), segment);
//         final segmentFileName = p.basename(segmentUrl.path);
//         final localSegmentFile = File(p.join(hlsCacheDirPath, segmentFileName));
//
//         if (!await localSegmentFile.exists()) {
//           AppLogger.info('Downloading segment ${downloadedSegments + 1} of $totalSegments: $segmentFileName', name: 'HlsCacheHandler');
//
//           await _downloadFile(
//             segmentUrl.toString(),
//             localSegmentFile,
//             encrypt: encrypt,
//           );
//         } else {
//           AppLogger.info('Segment ${downloadedSegments + 1} of $totalSegments already exists: $segmentFileName', name: 'HlsCacheHandler');
//         }
//
//         downloadedSegments++;
//         if (onProgress != null) {
//           onProgress(downloadedSegments, totalSegments);
//         }
//         AppLogger.info('Download progress: ${((downloadedSegments / totalSegments) * 100).toStringAsFixed(2)}%', name: 'HlsCacheHandler');
//       }
//
//       // 4. Rewrite the media playlist to use local paths
//       String rewrittenMediaPlaylistContent = _rewriteManifest(
//         mediaPlaylistContent,
//         hlsUri,
//         mediaPlaylistUrl,
//         hlsCacheDirPath,
//         trackId,
//       );
//
//       final String localMediaPlaylistFilePath = p.join(hlsCacheDirPath, p.basename(mediaPlaylistUrl));
//       final File localMediaPlaylistFile = File(localMediaPlaylistFilePath);
//
//       // Save the rewritten media playlist
//       await localMediaPlaylistFile.writeAsString(rewrittenMediaPlaylistContent);
//       AppLogger.info('Rewritten media playlist saved to: ${localMediaPlaylistFile.path}', name: 'HlsCacheHandler');
//
//       // 5. Rewrite the master manifest to point to the local media playlist
//       String rewrittenMasterManifestContent = masterManifestContent.replaceAll(
//         p.basename(mediaPlaylistUrl),
//         p.basename(localMediaPlaylistFilePath),
//       );
//
//       // Save the corrected content
//       final localMasterManifestFile = File(p.join(hlsCacheDirPath, 'master.m3u8'));
//       await localMasterManifestFile.writeAsString(rewrittenMasterManifestContent);
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
//   /// Deletes a cached HLS stream directory.
//   Future<void> deleteCachedHls(String hlsLocalDirPath) async {
//     final Directory hlsDir = Directory(hlsLocalDirPath);
//     if (await hlsDir.exists()) {
//       AppLogger.info('Deleting HLS cache directory: ${hlsDir.path}', name: 'HlsCacheHandler');
//       await hlsDir.delete(recursive: true);
//     }
//   }
//
//   // --- Private Helper Methods ---
//
//   /// Helper to resolve relative URIs against a base URI.
//   Uri _resolveUri(Uri baseUri, String relativePath) {
//     if (Uri.parse(relativePath).isAbsolute) {
//       return Uri.parse(relativePath);
//     }
//     return baseUri.resolve(relativePath);
//   }
//
//   /// Downloads a file and saves it to the local filesystem.
//   Future<void> _downloadFile(String url, File localFile, {bool encrypt = false}) async {
//     final http.Response response = await http.get(Uri.parse(url));
//     if (response.statusCode != 200) {
//       throw http.ClientException('Failed to download file from $url');
//     }
//     Uint8List fileBytes = response.bodyBytes;
//     if (encrypt) {
//       fileBytes = AESHelper.encrypt(fileBytes);
//     }
//     await localFile.writeAsBytes(fileBytes);
//   }
//
//   /// Dummy implementation for choosing the variant. This should be more sophisticated.
//   String? _chooseVariant(String masterManifestContent, Uri baseUri) {
//     // Find the line with EXT-X-STREAM-INF and a URI that ends with .m3u8
//     final RegExp playlistRegex = RegExp(r'^#EXT-X-STREAM-INF.*?\n(.*?\.m3u8)$', multiLine: true);
//     final match = playlistRegex.firstMatch(masterManifestContent);
//     if (match != null) {
//       final relativePath = match.group(1)!;
//       return _resolveUri(baseUri, relativePath).toString();
//     }
//     return null;
//   }
//
//   /// Dummy implementation for parsing segments.
//   List<String> _parseSegments(String mediaPlaylistContent) {
//     final segments = <String>[];
//     final RegExp segmentRegex = RegExp(r'^(?!#)(.*?\.ts)$', multiLine: true);
//     final matches = segmentRegex.allMatches(mediaPlaylistContent);
//     for (final match in matches) {
//       segments.add(match.group(1)!);
//     }
//     return segments;
//   }
//
//   /// Dummy implementation for rewriting the manifest.
//   String _rewriteManifest(
//       String manifestContent,
//       Uri originalBaseUri,
//       String originalManifestUrl,
//       String hlsLocalPath,
//       String trackId,
//       ) {
//     final String proxySegmentRoute = _proxyServer.proxySegmentRoute;
//     final int port = _proxyServer.port;
//     final RegExp urlPattern = RegExp(r'^(?!#)(.*\.ts|.*\.m3u8)$', multiLine: true);
//     final originalManifestBaseUri = Uri.parse(originalManifestUrl);
//
//     return manifestContent.replaceAllMapped(urlPattern, (match) {
//       String originalPath = match.group(1)!;
//       final String resolvedPath = originalManifestBaseUri.resolve(originalPath).pathSegments.join('/');
//       final String fullProxyPath = 'http://127.0.0.1:$port$proxySegmentRoute/$trackId/${resolvedPath}';
//       return fullProxyPath;
//     });
//   }
// }

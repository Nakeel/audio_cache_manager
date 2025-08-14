// lib/data/services/local_proxy_server.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as p; // Import path package

class LocalProxyServer {
  HttpServer? _server;
  final String cacheDirPath;
  final CacheMetadataStore metadataStore;
  int _port = 9999; // Will hold the dynamically assigned port

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port; // Expose the port for URI construction
  String get host => _server?.address.host ?? '127.0.0.1'; // Expose the host

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.', name: 'LocalProxyServer');
      return;
    }

    final Router _router = Router();

    // Existing route for MP3s and now the initial request for HLS
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null) {
        return Response.notFound('Track not found');
      }

      // Clarified log message for master manifest serving
      AppLogger.info('Serving HLS master manifest for track: $trackId, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer');

      if (entry.isHls) {
        final String localManifestPath = entry.hlsManifestFilePath!;
        final File manifestFile = File(localManifestPath);
        if (!await manifestFile.exists()) {
          AppLogger.error('HLS master manifest not found: $localManifestPath', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'HLS manifest not found.');
        }

        String manifestContent = await manifestFile.readAsString();
        // IMPORTANT FIX: Pass the correct proxySegmentRoute
        manifestContent = _rewriteHlsManifest(manifestContent, trackId, port, proxySegmentRoute: '/hls_segments');

        return Response.ok(manifestContent, headers: {
          'Content-Type': 'application/x-mpegURL', // MIME type for M3U8
          'Content-Length': manifestContent.length.toString(),
          'Accept-Ranges': 'bytes',
        });
      } else {
        // --- EXISTING MP3 LOGIC ---
        final File cachedFile = File(entry.filePath);
        if (!await cachedFile.exists()) {
          AppLogger.error('Cached file not found for MP3 track: ${entry.filePath}', name: 'LocalProxyServer');
          return Response.notFound('Cached file not found.');
        }
        Uint8List fileBytes = await cachedFile.readAsBytes();
        if (entry.isEncrypted) {
          AppLogger.info('Proxy server decrypting content for $trackId', name: 'LocalProxyServer');
          try {
            fileBytes = AESHelper.decrypt(fileBytes); // This is where the MP3 decrypt happens
          } catch (e, st) {
            AppLogger.error('Error decrypting MP3 file $trackId from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting audio: $e');
          }
        }
        return Response.ok(fileBytes, headers: {
          'Content-Type': entry.contentType,
          'Content-Length': fileBytes.length.toString(),
          'Accept-Ranges': 'bytes',
        });
      }
    });

    // --- NEW ROUTE FOR HLS SEGMENTS AND SUB-MANIFESTS ---
    _router.get('/hls_segments/<trackId>/<path|.*>', (Request request, String trackId, String path) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null || !entry.isHls || entry.hlsLocalPath == null) {
        return Response.notFound('HLS track not found or not an HLS entry.');
      }

      final String fullLocalPath = p.join(entry.hlsLocalPath!, path);
      final File hlsFile = File(fullLocalPath);

      if (!await hlsFile.exists()) {
        AppLogger.warning('HLS file not found: $fullLocalPath', name: 'LocalProxyServer');
        return Response.notFound('HLS segment or manifest not found locally.');
      }

      String contentType = 'application/octet-stream'; // Default
      if (path.endsWith('.m3u8')) {
        contentType = 'application/x-mpegURL';
      } else if (path.endsWith('.ts')) {
        contentType = 'video/mp2t'; // MPEG-2 Transport Stream
      } // Add other content types as needed

      Uint8List fileBytes = await hlsFile.readAsBytes();

      AppLogger.info('HLS segment: $path for track $trackId, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer'); // Added trackId for clarity
      if (entry.isEncrypted) {
        // If it's a segment (.ts) or a manifest that needs rewriting for proxying
        if (path.endsWith('.m3u8')) {
          // This is a media playlist. Rewrite its segment URLs to proxy.
          String manifestContent = String.fromCharCodes(fileBytes);
          // Correctly passing proxySegmentRoute to rewrite sub-manifests
          manifestContent = _rewriteHlsManifest(manifestContent, trackId, _port, basePath: path, proxySegmentRoute: '/hls_segments');
          fileBytes = Uint8List.fromList(manifestContent.codeUnits);
        } else if (path.endsWith('.ts')) { // Assuming segments are .ts and are encrypted
          AppLogger.info('Proxy server decrypting HLS segment: $path for track $trackId', name: 'LocalProxyServer');
          try {
            fileBytes = AESHelper.decrypt(fileBytes); // Decrypt the segment
          } catch (e, st) {
            AppLogger.error('Error decrypting HLS segment $path for track $trackId: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting HLS segment: $e');
          }
        }
      }

      return Response.ok(fileBytes, headers: {
        'Content-Type': contentType,
        'Content-Length': fileBytes.length.toString(),
        'Accept-Ranges': 'bytes',
      });
    });


    try {
      _server = await shelf_io.serve(_router, InternetAddress.loopbackIPv4, 0);
      // _port = _server!.port;
      AppLogger.info('LocalProxyServer running on http://$host:${_port}', name: 'LocalProxyServer');
    } catch (e, st) {
      AppLogger.error('Failed to start LocalProxyServer: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
      _server = null;
    }
  }

  /// Helper to get the full proxy URL for a given trackId.
  String getProxyUrl(String trackId) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate proxy URL.', name: 'LocalProxyServer');
      return ''; // Or throw an exception
    }
    return 'http://$host:${_port}/audio/$trackId';
  }

  /// Helper to get the full proxy URL for an HLS master manifest.
  /// This should be used when the master manifest URL is rewritten to point to the proxy.
  String getHlsManifestProxyUrl(String trackId, String originalManifestFileName) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate HLS manifest proxy URL.', name: 'LocalProxyServer');
      return ''; // Or throw an exception
    }
    // The HLS manifest route should be designed to handle the manifest file name.
    // For this setup, we use the general audio route, but with the specific filename if needed for distinction
    // For now, it's served by the /audio/<trackId> route, and the HlsCacheHandler rewrites the inner manifest paths.
    // If you need a distinct proxy route for HLS manifests, you'd add another router.get.
    return 'http://$host:${_port}/audio/$trackId';
  }

  // Helper method to rewrite HLS manifests to point to the proxy
  // This is a complex helper and will require careful implementation
   String _rewriteHlsManifest(String manifestContent, String trackId, int port, {String basePath = '', String proxySegmentRoute = '/hls_stream'}) {
    // Ensure the proxySegmentRoute starts with a '/'
       if (!proxySegmentRoute.startsWith('/')) {
         proxySegmentRoute = '/$proxySegmentRoute';
       }
    // This is a simplified example. Actual implementation needs robust parsing.
    // Use regex or a proper HLS manifest parser (if available)
    // to replace segment/sub-manifest paths with proxy URLs.

    // Example for a simple case, replacing .ts segments:
    // #EXTINF:10.0,
    // segment1.ts
    // would become:
    // #EXTINF:10.0,
    // http://127.0.0.1:CURRENT_PORT/hls_stream/<trackId>/segment1.ts

    final RegExp urlPattern = RegExp(r'^(?!#)(.*\.ts|.*\.m3u8)$', multiLine: true); // Matches lines that are not comments and end with .ts or .m3u8
    return manifestContent.replaceAllMapped(urlPattern, (match) {
      String originalPath = match.group(1)!;
      // Resolve against original base URI from HlsCacheHandler if needed,
      // but here we just need to ensure it's relative to the hlsLocalPath.
      // And then turn it into a proxy URL.

      // If it's a media playlist, the segments are relative to its own path.
      // So the path parameter in the route should be included in the local file path.
      // e.g., /hls_stream/trackId/variant/segment.ts
      final String resolvedPath = p.join(p.dirname(basePath), originalPath);

      // Construct the new proxy URL for this specific segment or sub-manifest
      final String fullProxyPath = 'http://127.0.0.1:$port$proxySegmentRoute/$trackId/$resolvedPath';
      AppLogger.info('Rewriting HLS URL: $originalPath (resolved to $resolvedPath) to $fullProxyPath', name: 'HlsProxyRewrite');
      return fullProxyPath;
    });
  }


  Future<void> stop() async {
    if (_server != null) {
      AppLogger.info('Stopping LocalProxyServer...', name: 'LocalProxyServer');
      await _server!.close(force: true); // Close forcefully
      _server = null;
      _port = 0;
      AppLogger.info('LocalProxyServer stopped.', name: 'LocalProxyServer');
    }
  }
}


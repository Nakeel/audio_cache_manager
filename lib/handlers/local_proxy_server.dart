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
import 'package:path/path.dart' as p;

class LocalProxyServer {
  HttpServer? _server;
  final String cacheDirPath;
  final CacheMetadataStore metadataStore;
  int _port = 0; // Will hold the dynamically assigned port

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port; // Expose the port for URI construction
  String get host => _server?.address.host ?? '127.0.0.1'; // Expose the host

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.', name: 'LocalProxyServer');
      return;
    }

    final Router _router = Router();

    // Route for MP3s and the main HLS master manifest (via trackId)
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null) {
        return Response.notFound('Track not found');
      }

      AppLogger.info('Serving request for track: $trackId, isHls: ${entry.isHls}, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer');

      if (entry.isHls) {
        // For HLS, this route serves the local master manifest.
        // The master manifest itself is already rewritten by HlsCacheHandler to point
        // to local segments (via /hls_segments route) or original URLs.
        final String localMasterManifestPath = p.join(entry.hlsLocalPath!, entry.hlsMasterManifestFileName!);
        final File manifestFile = File(localMasterManifestPath);
        if (!await manifestFile.exists()) {
          AppLogger.error('HLS master manifest not found: $localMasterManifestPath', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'HLS master manifest not found locally.');
        }

        String manifestContent = await manifestFile.readAsString();
        // No further rewriting needed here, as HlsCacheHandler already prepared it.
        // The master manifest points to the media playlist (which is local),
        // and the media playlist points to segments (local proxy or original URL).

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
          AppLogger.info('Proxy server decrypting content for MP3 $trackId', name: 'LocalProxyServer');
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
    // This route serves individual HLS segments (.ts) and potentially media playlists (.m3u8)
    // that are referenced by the master manifest.
    _router.get('/hls_segments/<trackId>/<path|.*>', (Request request, String trackId, String path) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null || !entry.isHls || entry.hlsLocalPath == null) {
        AppLogger.warning('HLS track not found or not an HLS entry for trackId: $trackId, path: $path', name: 'LocalProxyServer');
        return Response.notFound('HLS track not found or not an HLS entry.');
      }

      final String fullLocalPath = p.join(entry.hlsLocalPath!, path);
      final File hlsFile = File(fullLocalPath);

      if (!await hlsFile.exists()) {
        AppLogger.warning('HLS file not found locally: $fullLocalPath for track $trackId', name: 'LocalProxyServer');
        return Response.notFound('HLS segment or manifest not found locally.');
      }

      String contentType = 'application/octet-stream'; // Default
      if (path.endsWith('.m3u8')) {
        contentType = 'application/x-mpegURL';
      } else if (path.endsWith('.ts')) {
        contentType = 'video/mp2t'; // MPEG-2 Transport Stream
      } // Add other content types as needed

      Uint8List fileBytes = await hlsFile.readAsBytes();

      AppLogger.info('Serving HLS file: $path for track $trackId, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer');
      if (entry.isEncrypted) {
        // If it's a segment (.ts) that was encrypted during caching, decrypt it.
        // Media playlists (.m3u8) are not encrypted, but their contents are rewritten.
        if (path.endsWith('.ts')) {
          AppLogger.info('Proxy server decrypting HLS segment: $path for track $trackId', name: 'LocalProxyServer');
          try {
            fileBytes = AESHelper.decrypt(fileBytes); // Decrypt the segment
          } catch (e, st) {
            AppLogger.error('Error decrypting HLS segment $path for track $trackId: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting HLS segment: $e');
          }
        }
        // No need to rewrite manifest content here; HlsCacheHandler already did that.
        // The proxy just serves the file as-is after decryption.
      }

      return Response.ok(fileBytes, headers: {
        'Content-Type': contentType,
        'Content-Length': fileBytes.length.toString(),
        'Accept-Ranges': 'bytes',
      });
    });


    try {
      _server = await shelf_io.serve(_router, InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      AppLogger.info('LocalProxyServer running on http://$host:${_server!.port}', name: 'LocalProxyServer');
    } catch (e, st) {
      AppLogger.error('Failed to start LocalProxyServer: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
      _server = null;
    }
  }

  /// Helper to get the full proxy URL for a given trackId (for MP3s or main HLS manifest).
  String getProxyUrl(String trackId) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate proxy URL for trackId: $trackId', name: 'LocalProxyServer');
      return '';
    }
    return 'http://$host:${_server!.port}/audio/$trackId';
  }

  /// Helper to get the full proxy URL for an HLS segment or sub-manifest.
  String getHlsSegmentProxyUrl(String trackId, String relativePath) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate HLS segment proxy URL for trackId: $trackId, path: $relativePath', name: 'LocalProxyServer');
      return '';
    }
    // The `path` in the route is the relative path within the HLS track directory.
    // Ensure `relativePath` is correctly URL-encoded if it contains special characters.
    final encodedPath = Uri.encodeComponent(relativePath); // Encode the path
    return 'http://$host:${_server!.port}/hls_segments/$trackId/$encodedPath';
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

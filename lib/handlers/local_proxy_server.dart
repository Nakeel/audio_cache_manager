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

    // Route for serving audio files (e.g., http://127.0.0.1:<port>/audio/<trackId>)
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null) {
        AppLogger.warning('No cache entry found for $trackId in proxy.', name: 'LocalProxyServer');
        return Response.notFound('Not Found');
      }

      File fileToServe;
      // Determine the actual file path to serve based on content type
      if (entry.isHls) {
        // For HLS, if the request is for the master manifest, serve it.
        // HLS segments are handled by the HlsCacheHandler which should have decrypted them upon caching.
        // The proxy serves the decrypted manifest or segments directly from disk.
        if (entry.hlsManifestFilePath == null || !File(entry.hlsManifestFilePath!).existsSync()) {
          AppLogger.warning('HLS manifest not found for $trackId at ${entry.hlsManifestFilePath}', name: 'LocalProxyServer');
          return Response.notFound('HLS Manifest Not Found');
        }
        fileToServe = File(entry.hlsManifestFilePath!); // Serving the manifest file
      } else {
        // For MP3s, serve the actual cached file (which might be encrypted)
        if (!File(entry.filePath).existsSync()) {
          AppLogger.warning('File not found for $trackId at ${entry.filePath}', name: 'LocalProxyServer');
          return Response.notFound('File Not Found');
        }
        fileToServe = File(entry.filePath);
      }

      try {
        Uint8List fileBytes = await fileToServe.readAsBytes();

        // **NEW LOGIC: Decrypt if the content is marked as encrypted**
        if (entry.isEncrypted) {
          AppLogger.info('Proxy server decrypting content for ${entry.trackId}', name: 'LocalProxyServer');
          fileBytes = AESHelper.decrypt(fileBytes);
        }

        // Handle Range requests for seeking (important for audio players)
        final String? rangeHeader = request.headers['range'];
        int start = 0;
        int end = fileBytes.length - 1; // Default to full file

        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final String range = rangeHeader.substring(6); // Remove "bytes="
          final List<String> parts = range.split('-');
          start = int.parse(parts[0]);
          if (parts.length > 1 && parts[1].isNotEmpty) {
            end = int.parse(parts[1]);
          }
        }

        // Ensure end is within bounds
        if (end >= fileBytes.length) {
          end = fileBytes.length - 1;
        }

        final int contentLength = (end - start) + 1;
        final String contentRange = 'bytes $start-$end/${fileBytes.length}';

        final headers = {
          'Content-Type': entry.contentType,
          'Content-Length': contentLength.toString(),
          'Accept-Ranges': 'bytes', // Crucial for seeking
          'Content-Range': contentRange, // For partial content responses
          'Connection': 'keep-alive',
          // You might also include ETag and Last-Modified headers from CacheEntry if available
        };

        // If a range was requested, respond with 206 Partial Content
        final statusCode = (rangeHeader != null && (start > 0 || end < fileBytes.length - 1))
            ? HttpStatus.partialContent
            : HttpStatus.ok;

        return Response.ok(
          fileBytes.sublist(start, end + 1), // Serve only the requested range
          headers: headers,
        );
      } catch (e, st) {
        AppLogger.error('Error serving file ${entry.trackId} from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving audio: $e');
      }
    });

    // Route for serving HLS segments (if needed, otherwise the client might access them directly from the hlsLocalPath)
    // For this setup, we are serving master manifest via proxy, segments are direct or need another proxy route.
    // If HLS segments are to be decrypted by proxy, more complex routing will be needed.
    _router.get('/hls/<trackId>/<filename>', (Request request, String trackId, String filename) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null || !entry.isHls || entry.hlsLocalPath == null) {
        return Response.notFound('HLS track not found or not HLS');
      }

      final File segmentFile = File(p.join(entry.hlsLocalPath!, filename));
      if (!await segmentFile.exists()) {
        return Response.notFound('HLS segment not found');
      }

      try {
        Uint8List segmentBytes = await segmentFile.readAsBytes();
        // HLS segments should ideally be decrypted by HlsCacheHandler when cached,
        // so they are read already decrypted here. If they were still encrypted,
        // you'd add: if (entry.isEncrypted) { segmentBytes = AESHelper.decrypt(segmentBytes); }
        // based on your HLS caching strategy.

        return Response.ok(
          segmentBytes,
          headers: {
            'Content-Type': filename.endsWith('.ts') ? 'video/mp2t' : 'application/x-mpegURL',
            'Content-Length': segmentBytes.length.toString(),
            'Accept-Ranges': 'bytes',
          },
        );
      } catch (e, st) {
        AppLogger.error('Error serving HLS segment $filename for track $trackId from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving HLS segment: $e');
      }
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

  /// Helper to get the full proxy URL for a given trackId.
  String getProxyUrl(String trackId) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate proxy URL.', name: 'LocalProxyServer');
      return ''; // Or throw an exception
    }
    return 'http://$host:${_server!.port}/audio/$trackId';
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
    return 'http://$host:${_server!.port}/audio/$trackId';
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
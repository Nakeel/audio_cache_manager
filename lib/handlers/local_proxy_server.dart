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

// Assuming AESHelper is in a file like lib/data/encryption_helper.dart
// You might need to adjust the import if it's named something else or in a different path.

class LocalProxyServer {
  HttpServer? _server;
  final String cacheDirPath;
  final CacheMetadataStore metadataStore;
  int _port = 0; // Will hold the dynamically assigned port

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port; // Expose the port for URI construction

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.', name: 'LocalProxyServer');
      return;
    }

    final Router _router = Router();

    // Route for serving audio files (e.g., http://127.0.0.1:<port>/audio/<trackId>)
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      AppLogger.info('Proxy server request for trackId: $trackId', name: 'LocalProxyServer');
      final CacheEntry? cacheEntry = await metadataStore.get(trackId);

      if (cacheEntry == null || cacheEntry.isHls) {
        // Proxy should not serve HLS, or if entry is null
        AppLogger.warning('Track $trackId not found in cache metadata for proxy, or it is an HLS stream (not served by proxy).', name: 'LocalProxyServer');
        return Response.notFound('Track not found or HLS stream');
      }

      // Check if the file exists on disk
      // Use cacheEntry.filePath for MP3s/single files
      final File cachedFile = File(cacheEntry.filePath);
      if (!await cachedFile.exists()) {
        AppLogger.warning('Cached file not found on disk for $trackId at ${cacheEntry.filePath}', name: 'LocalProxyServer');
        return Response.notFound('File not found on disk');
      }

      // Determine content type (for MP3, it's typically audio/mpeg)
      final String contentType = cacheEntry.contentType; // Use cached content type

      // Read file and decrypt if necessary
      try {
        Uint8List fileBytes = await cachedFile.readAsBytes();

        if (cacheEntry.isEncrypted) {
          AppLogger.info('Decrypting file for $trackId...', name: 'LocalProxyServer');
          fileBytes = AESHelper.decrypt(fileBytes); // Decrypt using static AESHelper
          AppLogger.info('Decryption complete for $trackId.', name: 'LocalProxyServer');
        }

        // Create a stream from the bytes for efficient streaming
        final Stream<List<int>> byteStream = Stream.value(fileBytes);

        return Response.ok(
          byteStream,
          headers: {
            'Content-Type': contentType,
            'Content-Length': fileBytes.length.toString(), // Important for streaming players
            'Accept-Ranges': 'bytes', // Allows seeking
          },
        );
      } catch (e, st) {
        AppLogger.error('Error serving file $trackId from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving audio: $e');
      }
    });

    try {
      _server = await shelf_io.serve(_router, InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      AppLogger.info('LocalProxyServer running on http://${_server!.address.host}:${_server!.port}', name: 'LocalProxyServer');
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
    return 'http://${_server!.address.host}:${_server!.port}/audio/$trackId';
  }

  Future<void> stop() async {
    if (_server != null) {
      AppLogger.info('Stopping LocalProxyServer...', name: 'LocalProxyServer');
      await _server!.close(force: true);
      _server = null;
      _port = 0;
      AppLogger.info('LocalProxyServer stopped.', name: 'LocalProxyServer');
    }
  }
}
// lib/data/services/local_proxy_server.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/audio_cache_manager.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:shelf/shelf.dart'; // Add shelf and shelf_router to pubspec.yaml
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

class LocalProxyServer {
  HttpServer? _server;
  final String cacheDirPath;
  final CacheMetadataStore metadataStore; // Need to access CacheEntry
  int _port = 0; // Will hold the dynamically assigned port

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port; // Expose the port for URI construction

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.');
      return;
    }

    final Router _router = Router();

    // Route for serving audio files (e.g., http://localhost:<port>/audio/<trackId>)
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      AppLogger.info('Proxy server request for trackId: $trackId');
      final CacheEntry? cacheEntry = await metadataStore.get(trackId);

      if (cacheEntry == null) {
        AppLogger.warning('Track $trackId not found in cache metadata for proxy.');
        return Response.notFound('Track not found');
      }

      // Check if the file exists on disk
      final File cachedFile = File(cacheEntry.localPath);
      if (!await cachedFile.exists()) {
        AppLogger.warning('Cached file not found on disk for $trackId at ${cacheEntry.localPath}');
        return Response.notFound('File not found on disk');
      }

      // Determine content type (for MP3, it's typically audio/mpeg)
      final String contentType = 'audio/mpeg';

      // Read file and decrypt if necessary
      try {
        Uint8List fileBytes = await cachedFile.readAsBytes();

        if (cacheEntry.isEncrypted) {
          AppLogger.info('Decrypting file for $trackId...');
          fileBytes = AESHelper.decrypt(fileBytes); // Decrypt
          AppLogger.info('Decryption complete for $trackId.');
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
        AppLogger.error('Error serving file $trackId from proxy: $e', error: e, stackTrace: st);
        return Response.internalServerError(body: 'Error serving audio: $e');
      }
    });

    try {
      // Bind to an available port
      // Using InternetAddress.loopbackIPv4 ensures it's only accessible locally
      // Port 0 means the OS will assign a free port
      _server = await shelf_io.serve(_router, InternetAddress.loopbackIPv4, 0);
      _port = _server!.port; // Get the assigned port
      AppLogger.info('LocalProxyServer running on http://${_server!.address.host}:${_server!.port}');
    } catch (e, st) {
      AppLogger.error('Failed to start LocalProxyServer: $e', error: e, stackTrace: st);
      _server = null; // Ensure server is null if start fails
    }
  }

  Future<void> stop() async {
    if (_server != null) {
      AppLogger.info('Stopping LocalProxyServer...');
      await _server!.close(force: true); // Force close to ensure immediate shutdown
      _server = null;
      _port = 0;
      AppLogger.info('LocalProxyServer stopped.');
    }
  }
}
// lib/data/services/local_proxy_server.dart

import 'dart:io';
import 'dart:typed_data';
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

    // Route for serving MP3 audio files (e.g., http://127.0.0.1:<port>/audio/<trackId>)
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      AppLogger.info('Proxy request for MP3 track: $trackId', name: 'LocalProxyServer');
      final cacheEntry = await metadataStore.get(trackId);

      if (cacheEntry == null || cacheEntry.isHls) { // This route is for non-HLS (MP3s)
        AppLogger.warning('MP3 cache entry not found or is HLS for track $trackId. Returning 404.', name: 'LocalProxyServer');
        return Response.notFound('Audio not found or not an MP3');
      }

      final file = File(cacheEntry.filePath); // Use the direct file path
      if (!await file.exists()) {
        AppLogger.warning('Cached MP3 file does not exist: ${cacheEntry.filePath}', name: 'LocalProxyServer');
        return Response.notFound('Audio file not found on disk');
      }

      try {
        Uint8List fileBytes = await file.readAsBytes();

        if (cacheEntry.isEncrypted) {
          AppLogger.info('Decrypting MP3 for track: $trackId', name: 'LocalProxyServer');
          fileBytes = AESHelper.decrypt(fileBytes); // Decrypt if encrypted
        }

        return Response.ok(
          fileBytes,
          headers: {
            'Content-Type': cacheEntry.contentType, // e.g., 'audio/mpeg'
            'Content-Length': fileBytes.length.toString(), // Important for streaming players
            'Accept-Ranges': 'bytes', // Allows seeking
          },
        );
      } catch (e, st) {
        AppLogger.error('Error serving MP3 file $trackId from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving audio: $e');
      }
    });

    // NEW Route for serving HLS Manifests (e.g., http://127.0.0.1:<port>/hls_manifests/<trackId>/master.m3u8)
    _router.get('/hls_manifests/<trackId>/<manifestPath|.*>', (Request request, String trackId, String manifestPath) async {
      AppLogger.info('Proxy request for HLS manifest: $manifestPath for track: $trackId', name: 'LocalProxyServer');
      final cacheEntry = await metadataStore.get(trackId);

      if (cacheEntry == null || !cacheEntry.isHls || cacheEntry.hlsLocalPath == null) {
        AppLogger.warning('HLS manifest cache entry not found or invalid for track $trackId. Returning 404.', name: 'LocalProxyServer');
        return Response.notFound('HLS Manifest not found');
      }

      // Construct the local path to the manifest file within the HLS cache directory
      final String localManifestPath = p.join(cacheEntry.hlsLocalPath!, manifestPath);
      final File manifestFile = File(localManifestPath);

      if (!await manifestFile.exists()) {
        AppLogger.warning('Cached HLS manifest file does not exist: $localManifestPath', name: 'LocalProxyServer');
        return Response.notFound('HLS Manifest file not found on disk');
      }

      try {
        final String manifestContent = await manifestFile.readAsString();
        return Response.ok(
          manifestContent,
          headers: {
            'Content-Type': 'application/x-mpegURL', // Standard MIME type for M3U8
          },
        );
      } catch (e, st) {
        AppLogger.error('Error serving HLS manifest $localManifestPath from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving HLS manifest: $e');
      }
    });

    // NEW Route for serving HLS Segments (e.g., http://127.0.0.1:<port>/hls_segments/<trackId>/segment_00001.ts)
    _router.get('/hls_segments/<trackId>/<segmentPath|.*>', (Request request, String trackId, String segmentPath) async {
      AppLogger.info('Proxy request for HLS segment: $segmentPath for track: $trackId', name: 'LocalProxyServer');
      final cacheEntry = await metadataStore.get(trackId);

      if (cacheEntry == null || !cacheEntry.isHls || cacheEntry.hlsLocalPath == null) {
        AppLogger.warning('HLS segment cache entry not found or invalid for track $trackId. Returning 404.', name: 'LocalProxyServer');
        return Response.notFound('HLS Segment not found');
      }

      // Construct the local path to the segment file within the HLS cache directory
      final String localSegmentPath = p.join(cacheEntry.hlsLocalPath!, segmentPath);
      final File segmentFile = File(localSegmentPath);

      if (!await segmentFile.exists()) {
        AppLogger.warning('Cached HLS segment file does not exist: $localSegmentPath', name: 'LocalProxyServer');
        return Response.notFound('HLS Segment file not found on disk');
      }

      try {
        Uint8List fileBytes = await segmentFile.readAsBytes();

        if (cacheEntry.isEncrypted) {
          AppLogger.info('Decrypting HLS segment for track: $trackId, segment: $segmentPath', name: 'LocalProxyServer');
          fileBytes = AESHelper.decrypt(fileBytes); // Decrypt if encrypted
        }

        return Response.ok(
          fileBytes,
          headers: {
            'Content-Type': 'video/mp2t', // Standard MIME type for .ts segments
            'Content-Length': fileBytes.length.toString(),
            'Accept-Ranges': 'bytes',
          },
        );
      } catch (e, st) {
        AppLogger.error('Error serving HLS segment $localSegmentPath from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
        return Response.internalServerError(body: 'Error serving HLS segment: $e');
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

  /// Helper to get the full proxy URL for a given MP3 trackId.
  String getMp3ProxyUrl(String trackId) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate MP3 proxy URL.', name: 'LocalProxyServer');
      return '';
    }
    return 'http://${_server!.address.host}:${_server!.port}/audio/$trackId';
  }

  /// Helper to get the full proxy URL for an HLS master manifest.
  String getHlsManifestProxyUrl(String trackId, String masterManifestFileName) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate HLS manifest proxy URL.', name: 'LocalProxyServer');
      return '';
    }
    // HLS manifests will be served from a specific route
    return 'http://${_server!.address.host}:${_server!.port}/hls_manifests/$trackId/$masterManifestFileName';
  }


  Future<void> stop() async {
    if (_server != null) {
      AppLogger.info('Stopping LocalProxyServer...', name: 'LocalProxyServer');
      await _server!.close(force: true); // Use force: true for quicker shutdown
      _server = null;
      _port = 0;
      AppLogger.info('LocalProxyServer stopped.', name: 'LocalProxyServer');
    }
  }
}
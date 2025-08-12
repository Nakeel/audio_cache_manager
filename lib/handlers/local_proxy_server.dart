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
  int _port = 0;
  final String proxySegmentRoute = '/hls_segments';
  final String proxyKeyRoute = '/hls_keys';

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port;
  String get host => _server?.address.host ?? '127.0.0.1';

  String getProxyUrl(String trackId, {bool isHls = false}) {
    if (_server == null) {
      throw Exception('Proxy server is not running.');
    }
    if (isHls) {
      final CacheEntry? entry = metadataStore.getSync(trackId);
      if (entry == null || entry.hlsManifestFilePath == null) {
        throw Exception('HLS manifest path not found for trackId: $trackId');
      }
      final String manifestFileName = p.basename(entry.hlsManifestFilePath!);
      return 'http://$host:$port/audio/$trackId/$manifestFileName';
    } else {
      return 'http://$host:$port/audio/$trackId';
    }
  }

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.', name: 'LocalProxyServer');
      return;
    }
    final Router _router = Router();

    // Route for the initial HLS master manifest and other single files
    _router.get('/audio/<trackId>/<path|.*>', (Request request, String trackId, String path) async {
      AppLogger.info('Received request for path: $path on trackId: $trackId', name: 'LocalProxyServer');

      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null) {
        AppLogger.warning('Entry not found for trackId: $trackId', name: 'LocalProxyServer');
        return Response.notFound('Track not found.');
      }

      if (entry.isHls) {
        final String fullLocalPath = p.join(entry.hlsLocalPath!, path);
        final File file = File(fullLocalPath);

        if (!await file.exists()) {
          AppLogger.error('HLS file not found: $fullLocalPath', name: 'LocalProxyServer');
          return Response.notFound('HLS file not found locally.');
        }

        String contentType = 'application/octet-stream';
        if (path.endsWith('.m3u8')) {
          contentType = 'application/vnd.apple.mpegurl';
        } else if (path.endsWith('.ts')) {
          contentType = 'video/mp2t';
        }

        Uint8List fileBytes = await file.readAsBytes();

        if (path.endsWith('.m3u8')) {
          AppLogger.info('Serving HLS manifest: $path', name: 'LocalProxyServer');
          String manifestContent = String.fromCharCodes(fileBytes);
          manifestContent = _rewriteHlsManifest(manifestContent, trackId, port);
          fileBytes = Uint8List.fromList(manifestContent.codeUnits);
        } else if (path.endsWith('.ts') && entry.isEncrypted) {
          try {
            AppLogger.info('Serving encrypted HLS segment: $path. Decrypting...', name: 'LocalProxyServer');
            fileBytes = AESHelper.decrypt(fileBytes);
          } catch (e) {
            AppLogger.error('Error decrypting HLS segment: $path. Error: $e', name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting HLS segment.');
          }
        }

        return Response.ok(fileBytes, headers: {
          'Content-Type': contentType,
          'Content-Length': fileBytes.length.toString(),
          'Accept-Ranges': 'bytes',
        });
      } else {
        // Handle MP3 files
        final File cachedFile = File(entry.filePath!);
        if (!await cachedFile.exists()) {
          return Response.notFound('Cached MP3 file not found.');
        }
        Uint8List fileBytes = await cachedFile.readAsBytes();
        if (entry.isEncrypted) {
          try {
            AppLogger.info('Serving encrypted MP3: $path. Decrypting...', name: 'LocalProxyServer');
            fileBytes = AESHelper.decrypt(fileBytes);
          } catch (e) {
            AppLogger.error('Error decrypting MP3: $path. Error: $e', name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting audio.');
          }
        }
        AppLogger.info('Serving cached MP3: $path', name: 'LocalProxyServer');
        return Response.ok(fileBytes,
        //     headers: {
        //   'Content-Type': entry.contentType,
        //   'Content-Length': fileBytes.length.toString(),
        //   'Accept-Ranges': 'bytes',
        // }
        );
      }
    });

    // New dedicated route for HLS keys
    _router.get('$proxyKeyRoute/<trackId>/<keyFileName>', (Request request, String trackId, String keyFileName) async {
      AppLogger.info('Received request for HLS key: $keyFileName for trackId: $trackId', name: 'LocalProxyServer');
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null || !entry.isHls || entry.hlsLocalPath == null) {
        AppLogger.warning('HLS track not found or not an HLS entry for trackId: $trackId', name: 'LocalProxyServer');
        return Response.notFound('HLS track not found or not an HLS entry.');
      }

      final String fullLocalPath = p.join(entry.hlsLocalPath!, keyFileName);
      final File keyFile = File(fullLocalPath);

      if (!await keyFile.exists()) {
        AppLogger.warning('HLS key file not found: $fullLocalPath', name: 'LocalProxyServer');
        return Response.notFound('HLS key not found locally.');
      }

      Uint8List fileBytes = await keyFile.readAsBytes();

      if (entry.isEncrypted) {
        try {
          AppLogger.info('Serving encrypted HLS key: $keyFileName. Decrypting...', name: 'LocalProxyServer');
          fileBytes = AESHelper.decrypt(fileBytes);
        } catch (e, st) {
          AppLogger.error('Error decrypting HLS key $keyFileName for track $trackId: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
          return Response.internalServerError(body: 'Error decrypting HLS key: $e');
        }
      }

      return Response.ok(fileBytes, headers: {
        'Content-Type': 'application/octet-stream',
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
      _port = 0;
    }
  }

  String _rewriteHlsManifest(String manifestContent, String trackId, int port) {
    String rewrittenContent = manifestContent;
    final host = this.host;

    // Regex for HLS key URIs
    final keyPattern = RegExp(r'(#EXT-X-KEY:METHOD=AES-128,URI=")(.*?)(".*)');
    rewrittenContent = rewrittenContent.replaceAllMapped(keyPattern, (match) {
      final String originalKeyUrl = match.group(2)!;
      final String keyFileName = p.basename(originalKeyUrl);
      return '${match.group(1)}http://$host:$port$proxyKeyRoute/$trackId/$keyFileName${match.group(3)}';
    });

    // Regex for HLS segments and sub-manifests
    final urlPattern = RegExp(r'^(?!#)(.*\.ts|.*\.m3u8)$', multiLine: true);
    rewrittenContent = rewrittenContent.replaceAllMapped(urlPattern, (match) {
      final String originalUrl = match.group(0)!;
      final String fileName = p.basename(originalUrl);
      return 'http://$host:$port/audio/$trackId/$fileName';
    });

    return rewrittenContent;
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

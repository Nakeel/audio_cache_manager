// lib/data/services/local_proxy_server.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/models/hls_segment_entry.dart';
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

  static const String _masterManifestFileName = 'master.m3u8';
  static const String _mediaPlaylistFileName = 'media.m3u8';

  LocalProxyServer({required this.cacheDirPath, required this.metadataStore});

  int get port => _port;
  String get host => _server?.address.host ?? '127.0.0.1';

  Future<void> start() async {
    if (_server != null) {
      AppLogger.warning('LocalProxyServer already running.', name: 'LocalProxyServer');
      return;
    }

    final Router _router = Router();

    // Route for MP3s AND the main HLS master manifest
    _router.get('/audio/<trackId>', (Request request, String trackId) async {
      final CacheEntry? entry = await metadataStore.get(trackId);
      if (entry == null) {
        AppLogger.warning('Request for track $trackId but no cache entry found.', name: 'LocalProxyServer');
        return Response.notFound('Track not found');
      }

      AppLogger.info('Serving request for track: $trackId, isHls: ${entry.isHls}, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer');

      if (entry.isHls) {
        // For HLS, this route serves the master manifest.
        // It needs to be dynamically rewritten to include the current port.
        if (entry.hlsLocalPath == null) {
          AppLogger.error('HLS local path is null for track $trackId', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'HLS local path missing.');
        }

        final String originalMasterManifestPath = p.join(entry.hlsLocalPath!, _masterManifestFileName);
        final File manifestFile = File(originalMasterManifestPath);
        if (!await manifestFile.exists()) {
          AppLogger.error('HLS master manifest not found: $originalMasterManifestPath', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'HLS master manifest not found locally.');
        }

        String originalManifestContent = await manifestFile.readAsString();
        String rewrittenManifestContent = _rewriteHlsMasterManifest(originalManifestContent, trackId, port, entry.hlsLocalPath!);

        return Response.ok(rewrittenManifestContent, headers: {
          'Content-Type': 'application/x-mpegURL', // Correct MIME type for M3U8
          'Content-Length': rewrittenManifestContent.length.toString(),
          'Accept-Ranges': 'bytes', // Indicate support for range requests
          'Cache-Control': 'no-cache, no-store, must-revalidate', // Prevent client caching of this manifest
          'Pragma': 'no-cache',
          'Expires': '0',
        });
      } else {
        // --- MP3 LOGIC WITH INTEGRITY CHECK ---
        final File cachedFile = File(entry.filePath);
        if (!await cachedFile.exists()) {
          AppLogger.error('Cached file not found for MP3 track: ${entry.filePath}', name: 'LocalProxyServer');
          return Response.notFound('Cached file not found.');
        }

        Uint8List fileBytes = await cachedFile.readAsBytes();
        Uint8List contentToHash = fileBytes;

        if (entry.isEncrypted) {
          AppLogger.info('Proxy server decrypting content for MP3 $trackId', name: 'LocalProxyServer');
          try {
            contentToHash = AESHelper.decrypt(fileBytes);
          } catch (e, st) {
            AppLogger.error('Error decrypting MP3 file $trackId from proxy: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting audio: $e');
          }
        }

        if (entry.dataHash != null && !AESHelper.verifyIntegrity(contentToHash, entry.dataHash!)) {
          AppLogger.error('Data integrity check failed for MP3 track $trackId. Stored hash: ${entry.dataHash}, Calculated hash: ${AESHelper.calculateSha256(contentToHash)}', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'Data integrity check failed for audio track.');
        } else if (entry.dataHash == null) {
          AppLogger.warning('No data hash found for MP3 track $trackId. Cannot verify integrity.', name: 'LocalProxyServer');
        } else {
          AppLogger.info('Data integrity check passed for MP3 track $trackId.', name: 'LocalProxyServer');
        }

        return Response.ok(contentToHash, headers: {
          'Content-Type': entry.contentType,
          'Content-Length': contentToHash.length.toString(),
          'Accept-Ranges': 'bytes',
        });
      }
    });

    // --- ROUTE FOR HLS SEGMENTS AND SUB-MANIFESTS ---
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

      String contentType = 'application/octet-stream';
      if (path.endsWith('.m3u8')) {
        contentType = 'application/x-mpegURL';
        String originalMediaPlaylistContent = await hlsFile.readAsString();
        String rewrittenMediaPlaylistContent = _rewriteHlsMediaPlaylist(originalMediaPlaylistContent, trackId, port, entry.hlsSegments, p.dirname(path));
        return Response.ok(rewrittenMediaPlaylistContent, headers: {
          'Content-Type': contentType,
          'Content-Length': rewrittenMediaPlaylistContent.length.toString(),
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'no-cache, no-store, must-revalidate', // Prevent client caching of this manifest
          'Pragma': 'no-cache',
          'Expires': '0',
        });
      } else if (path.endsWith('.ts')) {
        contentType = 'video/mp2t'; // Correct MIME type for MPEG-2 Transport Stream
        Uint8List fileBytes = await hlsFile.readAsBytes();
        Uint8List contentToHash = fileBytes;

        AppLogger.info('Serving HLS segment: $path for track $trackId, isEncrypted: ${entry.isEncrypted}', name: 'LocalProxyServer');
        if (entry.isEncrypted) {
          AppLogger.info('Proxy server decrypting HLS segment: $path for track $trackId', name: 'LocalProxyServer');
          try {
            contentToHash = AESHelper.decrypt(fileBytes);
          } catch (e, st) {
            AppLogger.error('Error decrypting HLS segment $path for track $trackId: $e', error: e, stackTrace: st, name: 'LocalProxyServer');
            return Response.internalServerError(body: 'Error decrypting HLS segment: $e');
          }
        }

        final HlsSegmentEntry? segmentEntry = entry.hlsSegments?.firstWhereOrNull((s) => s.localRelativePath == path);
        if (segmentEntry != null && segmentEntry.dataHash != null && !AESHelper.verifyIntegrity(contentToHash, segmentEntry.dataHash!)) {
          AppLogger.error('Data integrity check failed for HLS segment $path (track $trackId). Stored hash: ${segmentEntry.dataHash}, Calculated hash: ${AESHelper.calculateSha256(contentToHash)}', name: 'LocalProxyServer');
          return Response.internalServerError(body: 'Data integrity check failed for HLS segment.');
        } else if (segmentEntry?.dataHash == null) {
          AppLogger.warning('No data hash found for HLS segment $path (track $trackId). Cannot verify integrity.', name: 'LocalProxyServer');
        } else {
          AppLogger.info('Data integrity check passed for HLS segment $path (track $trackId).', name: 'LocalProxyServer');
        }

        return Response.ok(contentToHash, headers: {
          'Content-Type': contentType,
          'Content-Length': contentToHash.length.toString(),
          'Accept-Ranges': 'bytes',
        });
      } else {
        AppLogger.warning('Unsupported HLS file type requested: $path', name: 'LocalProxyServer');
        return Response.badRequest(body: 'Unsupported HLS file type.');
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

  String getProxyUrl(String trackId) {
    if (_server == null || _port == 0) {
      AppLogger.warning('Proxy server not running. Cannot generate proxy URL for trackId: $trackId', name: 'LocalProxyServer');
      return '';
    }
    return 'http://$host:${_server!.port}/audio/$trackId';
  }

  String _getHlsSegmentOrManifestProxyUrl(String trackId, String relativePath, int currentPort) {
    final encodedPath = Uri.encodeComponent(relativePath);
    return 'http://$host:$currentPort/hls_segments/$trackId/$encodedPath';
  }

  String _rewriteHlsMasterManifest(String masterManifestContent, String trackId, int currentPort, String hlsLocalPath) {
    final String mediaPlaylistRelativePath = _mediaPlaylistFileName;
    final RegExp streamInfPattern = RegExp(r'^(#EXT-X-STREAM-INF.*)\n(?!#)(.*)', multiLine: true);

    return masterManifestContent.replaceAllMapped(streamInfPattern, (match) {
      final String streamInfLine = match.group(1)!;
      final String proxyMediaPlaylistUrl = _getHlsSegmentOrManifestProxyUrl(trackId, mediaPlaylistRelativePath, currentPort);
      AppLogger.info('Rewriting master manifest: $streamInfLine to $proxyMediaPlaylistUrl', name: 'LocalProxyServer');
      return '$streamInfLine\n$proxyMediaPlaylistUrl';
    });
  }

  String _rewriteHlsMediaPlaylist(String mediaPlaylistContent, String trackId, int currentPort, List<HlsSegmentEntry>? cachedSegments, String currentManifestRelativeDir) {
    final RegExp urlPattern = RegExp(r'^(?!#)(.*\\.ts|.*\\.m3u8)$', multiLine: true);

    return mediaPlaylistContent.replaceAllMapped(urlPattern, (match) {
      String originalRelativePath = match.group(1)!;

      // Normalize the path to match how it's stored in HlsSegmentEntry
      final String segmentLocalRelativePath = p.normalize(p.join(currentManifestRelativeDir, originalRelativePath));
      AppLogger.info('Rewriting media playlist: Original relative path: $originalRelativePath, Normalized local path: $segmentLocalRelativePath', name: 'LocalProxyRewrite');


      final HlsSegmentEntry? segmentEntry = cachedSegments?.firstWhereOrNull((s) => s.localRelativePath == segmentLocalRelativePath);

      if (segmentEntry != null && segmentEntry.isComplete) {
        final String fullProxyPath = _getHlsSegmentOrManifestProxyUrl(trackId, segmentEntry.localRelativePath, currentPort);
        AppLogger.info('Rewriting media playlist URL: $originalRelativePath (local: $segmentLocalRelativePath) to proxy: $fullProxyPath', name: 'LocalProxyRewrite');
        return fullProxyPath;
      } else {
        AppLogger.info('Keeping original media playlist URL (incomplete/missing): $originalRelativePath (local: $segmentLocalRelativePath)', name: 'LocalProxyRewrite');
        return originalRelativePath;
      }
    });
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

extension on List<HlsSegmentEntry> {
  HlsSegmentEntry? firstWhereOrNull(bool Function(HlsSegmentEntry) test) {
    for (var element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}

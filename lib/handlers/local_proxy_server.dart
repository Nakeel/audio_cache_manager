// lib/handlers/local_proxy_server.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path/path.dart' as p;

// Define types for callbacks from AudioCacheManager
// Now expects trackId as the key for lookup
typedef GetCacheEntryFunction = Future<CacheEntry?> Function(String trackId);
typedef IsUserSubscribedFunction = bool Function();

/// Manages a local HTTP server to proxy cached HLS segments, rewritten manifests,
/// and encrypted MP3s, performing decryption on-the-fly.
class LocalProxyServer {
  HttpServer? _server;
  int _port = 0;

  // Callbacks to get necessary data from the main cache manager
  late GetCacheEntryFunction _getCacheEntry;
  late IsUserSubscribedFunction _isUserSubscribed;
  late bool Function() _isEncryptionEnabled;

  int get port => _port;

  /// Initializes and starts the local HTTP server.
  Future<void> init({
    required GetCacheEntryFunction getCacheEntry,
    required IsUserSubscribedFunction isUserSubscribed,
    required bool Function() isEncryptionEnabled,
  }) async {
    _getCacheEntry = getCacheEntry;
    _isUserSubscribed = isUserSubscribed;
    _isEncryptionEnabled = isEncryptionEnabled;

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_handleRequest);

    try {
      _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      print('LocalProxyServer started on port: $_port');
    } catch (e) {
      print('Error starting LocalProxyServer: $e');
      throw Exception('Failed to start local proxy server: $e');
    }
  }

  /// Generates a proxy URL for an HLS playlist (rewritten master/sub-manifest).
  /// Now takes manifestFileName to specify which HLS manifest to serve from the track's directory.
  String getHlsPlaylistProxyUrl(String trackId, String manifestFileName) {
    // THIS IS THE CORRECTED PART:
    // The proxy URL should only point to the local file, not include original CDN tokens/wildcards.
    return 'http://127.0.0.1:$_port/hls_manifests/$trackId/$manifestFileName';
    // Changed path segment to hls_manifests to differentiate from segment requests if needed.
    // Or keep 'hls' but ensure the regex correctly handles it.
  }

  /// Generates a proxy URL for an HLS segment or other HLS-related file.
  String getHlsSegmentProxyUrl(String trackId, String segmentFileName) {
    // Same logic: should not contain original URL's tokens
    return 'http://127.0.0.1:$_port/hls_segments/$trackId/$segmentFileName';
    // Changed path segment to hls_segments
  }

  /// Generates a proxy URL for an encrypted MP3 file.
  String getMp3ProxyUrl(String trackId) {
    // We don't need the actual filename here, as the proxy knows to look up by trackId
    // and the CacheEntry will give it the full path including .enc if encrypted.
    return 'http://127.0.0.1:$_port/mp3/$trackId';
  }

  /// The main request handler for the local HTTP server.
  Future<Response> _handleRequest(Request request) async {
    final String path = request.url.path;
    print('Proxy Request: ${request.method} ${request.url}');

    final hlsManifestMatch = RegExp(r'^hls_manifests/([^/]+)/(.+)$').firstMatch(path);
    if (hlsManifestMatch != null) {
      final trackId = hlsManifestMatch.group(1)!;
      final fileName = hlsManifestMatch.group(2)!; // This should be 'master.m3u8' or 'proxy_playlist.m3u8'

      final CacheEntry? entry = await _getCacheEntry(trackId);
      if (entry == null || !entry.isHls) {
        print('Proxy: HLS manifest metadata not found or not HLS for $trackId');
        return Response.notFound('HLS track metadata not found or not HLS: $trackId');
      }

      final String fullLocalPath = p.join(entry.localPath, fileName); // entry.localPath is the track's directory
      final File file = File(fullLocalPath);

      if (!await file.exists()) {
        print('Proxy: HLS manifest file not found in cache: $fullLocalPath');
        return Response.notFound('HLS manifest file not found in cache: $fullLocalPath');
      }

      return await _serveFile(file, entry.isEncrypted);
    }

    // Example path: hls_segments/{trackId}/{segmentFileName.ts}
    final hlsSegmentMatch = RegExp(r'^hls_segments/([^/]+)/(.+)$').firstMatch(path);
    if (hlsSegmentMatch != null) {
      final trackId = hlsSegmentMatch.group(1)!;
      final fileName = hlsSegmentMatch.group(2)!; // This should be 'segment0001.ts' etc.

      final CacheEntry? entry = await _getCacheEntry(trackId);
      if (entry == null || !entry.isHls) {
        print('Proxy: HLS segment metadata not found or not HLS for $trackId');
        return Response.notFound('HLS track metadata not found or not HLS: $trackId');
      }

      final String fullLocalPath = p.join(entry.localPath, fileName); // entry.localPath is the track's directory
      final File file = File(fullLocalPath);

      if (!await file.exists()) {
        print('Proxy: HLS segment file not found in cache: $fullLocalPath');
        return Response.notFound('HLS segment file not found in cache: $fullLocalPath');
      }

      return await _serveFile(file, entry.isEncrypted);
    }

    // Example path: mp3/{trackId} (No change needed here, it was already fine)
    final mp3Match = RegExp(r'^mp3/([^/]+)$').firstMatch(path);
    if (mp3Match != null) {
      final trackId = mp3Match.group(1)!;

      final CacheEntry? entry = await _getCacheEntry(trackId);
      if (entry == null || entry.isHls || !entry.isEncrypted) {
        print('Proxy: MP3 track metadata not found or not encrypted: $trackId');
        return Response.notFound('MP3 track metadata not found or not encrypted: $trackId');
      }

      final File file = File(entry.localPath);
      if (!await file.exists()) {
        print('Proxy: MP3 file not found in cache: ${entry.localPath}');
        return Response.notFound('MP3 file not found in cache: ${entry.localPath}');
      }

      final isEncryptionEnabled = _isEncryptionEnabled();
      return await _serveFile(file, isEncryptionEnabled);
    }

    return Response.notFound('Invalid cached content request: ${request.url}');
  }

  /// Serves a file from the local cache, with optional on-the-fly decryption.
  Future<Response> _serveFile(File file, bool isEncrypted) async {
    try {
      if (isEncrypted) {
        if (!_isUserSubscribed()) {
          // Deny access if encrypted and user is not subscribed
          print('Proxy: Access denied: User not subscribed for encrypted content.');
          return Response.forbidden('Subscription required to access this content.');
        }
        // Decrypt on-the-fly and stream the decrypted bytes
        final encryptedBytes = await file.readAsBytes();
        final decryptedBytes = AESHelper.decryptData(encryptedBytes);
        return Response.ok(decryptedBytes, headers: {'Content-Type': _getContentType(file.path)});
      } else {
        // Serve unencrypted file directly
        return Response.ok(file.openRead(), headers: {'Content-Type': _getContentType(file.path)});
      }
    } catch (e) {
      print('Proxy: Error serving file ${file.path}: $e');
      return Response.internalServerError(body: 'Error serving file: $e');
    }
  }

  /// Determines the Content-Type header based on file extension.
  String _getContentType(String filePath) {
    if (filePath.endsWith('.m3u8')) return 'application/x-mpegURL';
    if (filePath.endsWith('.ts')) return 'video/mp2t'; // MPEG-2 Transport Stream
    if (filePath.endsWith('.mp3')) return 'audio/mpeg';
    if (filePath.endsWith('.aac')) return 'audio/aac';
    if (filePath.endsWith('.mp4')) return 'video/mp4';
    return 'application/octet-stream';
  }

  /// Stops the local HTTP server.
  Future<void> dispose() async {
    await _server?.close(force: true);
    print('LocalProxyServer disposed.');
  }
}
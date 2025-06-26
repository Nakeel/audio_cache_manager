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
    return '${_server?.address.host}:$_port/hls_manifests/$trackId/$manifestFileName';
    // Changed path segment to hls_manifests to differentiate from segment requests if needed.
    // Or keep 'hls' but ensure the regex correctly handles it.
  }

  /// Generates a proxy URL for an HLS segment or other HLS-related file.
  String getHlsSegmentProxyUrl(String trackId, String segmentFileName) {
    // Same logic: should not contain original URL's tokens
    return '${_server?.address.host}:$_port/hls_segments/$trackId/$segmentFileName';
    // Changed path segment to hls_segments
  }

  /// Generates a proxy URL for an encrypted MP3 file.
  String getMp3ProxyUrl(String trackId) {
    // We don't need the actual filename here, as the proxy knows to look up by trackId
    // and the CacheEntry will give it the full path including .enc if encrypted.
    return '${_server?.address.host}:$_port/mp3/$trackId';
  }

  /// The main request handler for the local HTTP server.
  Future<Response> _handleRequest(Request request) async {
    final path = request.url.path; // Use request.url.path for shelf.Request
    print('Proxy Request: ${request.method} /$path');

    final RegExp hlsPlaylistPattern = RegExp(r'hls_playlists/([^/]+)/(.+\.m3u8)$');
    final RegExp hlsSegmentPattern = RegExp(r'hls_segments/([^/]+)/(.+\.(?:ts|mp4|aac))$');
    final RegExp mp3Pattern = RegExp(r'mp3_files/([^/]+)$'); // Assuming your MP3 proxy URL looks like this

    String? trackId;
    String? fileName;
    bool isHlsManifest = false;
    bool isHlsSegment = false;
    bool isMp3 = false;

    Match? match;

    if (hlsPlaylistPattern.hasMatch(path)) {
      match = hlsPlaylistPattern.firstMatch(path);
      trackId = match?.group(1);
      fileName = match?.group(2); // e.g., master.m3u8 or variant.m3u8
      isHlsManifest = true;
    } else if (hlsSegmentPattern.hasMatch(path)) {
      match = hlsSegmentPattern.firstMatch(path);
      trackId = match?.group(1);
      fileName = match?.group(2); // e.g., segment0001.ts
      isHlsSegment = true;
    } else if (mp3Pattern.hasMatch(path)) {
      match = mp3Pattern.firstMatch(path);
      trackId = match?.group(1); // For MP3, trackId is the filename
      // Assuming MP3s are stored directly with trackId.mp3 or trackId.mp3.enc
      // You might need to adjust fileName derivation based on your actual MP3 caching naming.
      // For now, let's assume it's just the trackId if the proxy path only includes trackId.
      // If your MP3 proxy URL is /mp3_files/trackId/trackId.mp3.enc, you'd extract that.
      // For simplicity here, assuming 'trackId' directly maps to 'fileName' with its extension.
      fileName = trackId; // This needs to be correctly derived from your actual file naming convention
      isMp3 = true;
    }

    if (trackId == null || fileName == null) {
      print('Proxy: Invalid request path: /$path');
      return Response.notFound('Invalid request path');
    }

    // Retrieve the cache entry for validation and file path
    final CacheEntry? cacheEntry = await _getCacheEntry(trackId);

    if (cacheEntry == null) {
      print('Proxy: Cache entry not found for trackId: $trackId');
      return Response.notFound('Track not found in cache');
    }

    // Determine the actual local file path based on the type of request
    File fileToServe;
    String? effectiveLocalPath;

    if (isHlsManifest || isHlsSegment) {
      effectiveLocalPath = p.join(cacheEntry.localPath, fileName);
    } else if (isMp3) {
      // For MP3s, cacheEntry.localPath already points to the file
      effectiveLocalPath = cacheEntry.localPath;
    } else {
      print('Proxy: Unhandled file type in path: /$path');
      return Response.badRequest(body: 'Unhandled file type');
    }

    fileToServe = File(effectiveLocalPath!);

    if (!await fileToServe.exists()) {
      print('Proxy: Requested file not found on disk: ${fileToServe.path}');
      return Response.notFound('File not found on disk');
    }

    // --- Handle Decryption ---
    Uint8List bytes = await fileToServe.readAsBytes();
    if (_isEncryptionEnabled() && cacheEntry.isEncrypted) {
      try {
        bytes = AESHelper.decryptData(bytes);
        print('Proxy: Decrypted ${fileToServe.path}');
      } catch (e) {
        print('Proxy: Decryption failed for ${fileToServe.path}: $e', );
        return Response.internalServerError(body: 'Decryption failed');
      }
    }

    // --- Determine Content-Type ---
    ContentType? contentType;
    if (isHlsManifest) {
      contentType = ContentType.parse('application/vnd.apple.mpegurl');
    } else if (isHlsSegment) {
      contentType = ContentType.parse('video/mp2t'); // Common for .ts segments
    } else if (isMp3) {
      contentType = ContentType.parse('audio/mpeg');
    } else {
      // Fallback for other types, though we should handle all expected
      contentType = ContentType.parse('application/octet-stream');
    }

    print('${request.method} 200 /$path');
    return Response.ok(bytes, headers: {'Content-Type': contentType.toString()});
  }


  // // Helper methods to generate proxy URLs (these remain largely the same, but ensure they match the Regex patterns)
  // String getHlsPlaylistProxyUrl(String trackId, String manifestFileName) {
  //   return 'http://${InternetAddress.loopbackIPv4.host}:$_port/hls_playlists/$trackId/$manifestFileName';
  // }
  //
  // String getHlsSegmentProxyUrl(String trackId, String segmentFileName) {
  //   return 'http://${InternetAddress.loopbackIPv4.host}:$_port/hls_segments/$trackId/$segmentFileName';
  // }
  //
  // String getMp3ProxyUrl(String trackId) {
  //   // This assumes your MP3 proxy serves the trackId as the key directly
  //   return 'http://${InternetAddress.loopbackIPv4.host}:$_port/mp3_files/$trackId';
  // }

  // // To properly dispose the server
  // Future<void> dispose() async {
  //   // You need to store the server instance created by shelf_io.serve
  //   // For simplicity, I'll add a late final field _server here.
  //   // late final HttpServer _server; // Add this to your class fields
  //   // if (_server != null) {
  //   //   await _server.close(force: true);
  //   //   print('LocalProxyServer stopped.');
  //   // }
  // }


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
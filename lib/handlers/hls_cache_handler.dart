import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'dart:async';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'dart:convert';



class HlsCacheHandler {
  static const int _maxSegmentRetries = 3;
  static const Duration _retryDelay = Duration(seconds: 2);

  final LocalProxyServer _proxyServer;

  HlsCacheHandler({required LocalProxyServer proxyServer}) : _proxyServer = proxyServer;
  
  /// Downloads an HLS stream, caching one variant and rewriting playlists.
  /// Returns the path to the local master playlist.
  Future<String?> cacheHls(
      String hlsUrl,
      String cacheBaseDir,
      String trackId, {
        void Function(int received, int total)? onProgress,
        bool encrypt = false,
      }) async {
    final cacheDir = Directory(p.join(cacheBaseDir, trackId));

    try {
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
        AppLogger.info("[HLS] Created cache dir: ${cacheDir.path}");
      }

      AppLogger.info("[HLS] Downloading master playlist...");
      final masterContent = await _downloadText(hlsUrl);
      if (masterContent == null) {
        AppLogger.info("[HLS] Failed to download master playlist.");
        return null;
      }

      AppLogger.info("[HLS] Selecting first variant...");
      final variantUrl = _extractFirstVariant(hlsUrl, masterContent) ?? hlsUrl;

      AppLogger.info("[HLS] Downloading media playlist: $variantUrl");
      final mediaContent = await _downloadText(variantUrl);
      if (mediaContent == null) {
        AppLogger.info("[HLS] Failed to download media playlist.");
        return null;
      }

      AppLogger.info("[HLS] Extracting segment URLs...");
      final segmentUrls = _extractSegmentUrls(variantUrl, mediaContent);
      AppLogger.info("[HLS] Found ${segmentUrls.length} segments.");

      int count = 0;
      for (final segUrl in segmentUrls) {
        AppLogger.info("[HLS] Downloading segment ${count + 1}/${segmentUrls.length}");
        final segBytes = await _downloadBytes(segUrl);
        if (segBytes == null) continue;

        final data = encrypt ? AESHelper.encrypt(segBytes) : segBytes;
        final segName = '${trackId}_${p.basename(Uri.parse(segUrl).path)}';
        await File(p.join(cacheDir.path, segName)).writeAsBytes(data);

        count++;
        onProgress?.call(count, segmentUrls.length);
      }

      AppLogger.info("[HLS] Rewriting media playlist...");
      final localMediaPlaylist = _rewriteMediaPlaylist(
        variantUrl,
        mediaContent,
        trackId,
      );
      final mediaPlaylistFile = File(
        p.join(cacheDir.path, p.basename(Uri.parse(variantUrl).path)),
      );
      await mediaPlaylistFile.writeAsString(localMediaPlaylist);

      AppLogger.info("[HLS] Rewriting master playlist...");
      final localMasterPlaylist = _rewriteMasterPlaylist(
        hlsUrl,
        masterContent,
        p.basename(mediaPlaylistFile.path),
      );
      final masterFile = File(
        p.join(cacheDir.path, p.basename(Uri.parse(hlsUrl).path)),
      );
      await masterFile.writeAsString(localMasterPlaylist);

      AppLogger.info("[HLS] Caching complete. Master path: ${masterFile.path}");
      return masterFile.path;
    } catch (e) {
      AppLogger.info("[HLS] Error: $e");
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        AppLogger.info("[HLS] Cleaned up cache dir due to error.");
      }
      return null;
    }
  }

  /// Helpers

  Future<String?> _downloadText(String url) async {
    final res = await http.get(Uri.parse(url));
    return res.statusCode == 200 ? res.body : null;
  }

  Future<Uint8List?> _downloadBytes(String url) async {
    final res = await http.get(Uri.parse(url));
    return res.statusCode == 200 ? res.bodyBytes : null;
  }

  String? _extractFirstVariant(String masterUrl, String content) {
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
        return Uri.parse(masterUrl).resolve(lines[i + 1].trim()).toString();
      }
    }
    return null;
  }

  List<String> _extractSegmentUrls(String playlistUrl, String content) {
    final baseUri = Uri.parse(playlistUrl);
    return content
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((seg) => baseUri.resolve(seg).toString())
        .toList();
  }

  String _rewriteMediaPlaylist(
      String playlistUrl,
      String content,
      String trackId,
      ) {
    final baseUri = Uri.parse(playlistUrl);
    return content.split('\n').map((line) {
      if (line.isNotEmpty && !line.startsWith('#')) {
        final segName = '${trackId}_${p.basename(baseUri.resolve(line).path)}';
        return segName;
      }
      return line;
    }).join('\n');
  }

  String _rewriteMasterPlaylist(
      String masterUrl,
      String content,
      String localMediaFile,
      ) {
    final lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
        lines[i + 1] = localMediaFile;
        break;
      }
    }
    return lines.join('\n');
  }

  /// Helper to resolve relative URIs against a base URI.
  Uri _resolveUri(Uri baseUri, String relativePath) {
    if (Uri.parse(relativePath).isAbsolute) {
      return Uri.parse(relativePath);
    }
    // Use resolve for better URI handling, it handles '..' and other URI specifics
    return baseUri.resolve(relativePath);
  }

  /// Deletes a cached HLS stream directory.
  Future<void> deleteCachedHls(String hlsLocalDirPath) async {
    final Directory hlsDir = Directory(hlsLocalDirPath);
    if (await hlsDir.exists()) {
      AppLogger.info('Deleting HLS cache directory: ${hlsDir.path}', name: 'HlsCacheHandler');
      await hlsDir.delete(recursive: true);
    }
  }
}
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/aes_encryptor.dart';
import 'package:path_provider/path_provider.dart';

class HlsCacheHandler {
  Future<File?> download(String url, {bool encrypt = false, required String encryptionKey, required String trackId}) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final m3u8Content = utf8.decode(response.bodyBytes);
      final segments = _parseM3u8Segments(m3u8Content, url);
      final dir = await getTemporaryDirectory();
      final trackDir = Directory('${dir.path}/audio_cache/hls_$trackId');
      await trackDir.create(recursive: true);

      for (final segment in segments) {
        final segmentUrl = _resolveSegmentUrl(segment, url);
        final segmentResponse = await http.get(Uri.parse(segmentUrl));
        if (segmentResponse.statusCode == 200) {
          final segmentFile = File('${trackDir.path}/${segment.hashCode}.ts');
          if (encrypt) {
            final aes = AESHelper(encryptionKey);
            final encrypted = aes.encryptData(segmentResponse.bodyBytes);
            await segmentFile.writeAsBytes(encrypted);
          } else {
            await segmentFile.writeAsBytes(segmentResponse.bodyBytes);
          }
        }
      }

      final localM3u8 = File('${trackDir.path}/playlist.m3u8');
      await localM3u8.writeAsString(m3u8Content.replaceAllMapped(
          RegExp(r'^(https?://.*\.ts)$', multiLine: true),
              (match) => '${trackDir.path}/${match[0]!.hashCode}.ts'));

      return localM3u8;
    } catch (e) {
      print('Error downloading HLS track: $e');
      return null;
    }
  }

  List<String> _parseM3u8Segments(String m3u8Content, String baseUrl) {
    final segments = <String>[];
    final lines = m3u8Content.split('\n');
    for (final line in lines) {
      if (line.trim().endsWith('.ts')) {
        segments.add(line.trim());
      }
    }
    return segments;
  }

  String _resolveSegmentUrl(String segment, String baseUrl) {
    if (segment.startsWith('http')) return segment;
    return Uri.parse(baseUrl).resolve(segment).toString();
  }
}
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/aes_encryptor.dart';
import 'package:path_provider/path_provider.dart';

class HlsCacheHandler {
  HttpServer? _server;

  Future<void> startServer() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8000);
    _server?.listen((HttpRequest request) async {
      final urlParam = Uri.decodeFull(request.uri.queryParameters['url'] ?? '');
      if (urlParam.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final proxyResponse = await http.get(Uri.parse(urlParam));
      request.response.statusCode = proxyResponse.statusCode;
      request.response.headers.contentType = ContentType("application", "vnd.apple.mpegurl");
      request.response.add(proxyResponse.bodyBytes);
      await request.response.close();
    });
  }

  Future<File?> download(String url, {bool encrypt = false}) async {
    final uri = Uri.parse(url);
    final response = await http.get(uri);
    if (response.statusCode != 200) return null;

    final dir = await getTemporaryDirectory();
    final filePath = '\${dir.path}/\${md5.convert(utf8.encode(url))}.m3u8';
    final file = File(filePath);

    if (encrypt) {
      final encrypted = AESHelper.encryptData(response.bodyBytes);
      await file.writeAsBytes(encrypted);
    } else {
      await file.writeAsBytes(response.bodyBytes);
    }

    return file;
  }

  String getProxiedUrl(String originalUrl) {
    return 'http://127.0.0.1:8000/?url=\${Uri.encodeComponent(originalUrl)}';
  }

  Future<void> stopServer() async {
    await _server?.close();
  }
}
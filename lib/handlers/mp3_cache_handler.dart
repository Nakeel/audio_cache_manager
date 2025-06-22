import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/aes_encryptor.dart';
import 'package:path_provider/path_provider.dart';

class Mp3CacheHandler {
  Future<File?> download(String url, {bool encrypt = false}) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) return null;

    final dir = await getTemporaryDirectory();
    final filePath = '\${dir.path}/\${md5.convert(utf8.encode(url))}.mp3';
    final file = File(filePath);

    if (encrypt) {
      final encrypted = AESHelper.encryptData(response.bodyBytes);
      await file.writeAsBytes(encrypted);
    } else {
      await file.writeAsBytes(response.bodyBytes);
    }

    return file;
  }
}
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../utils/aes_encryptor.dart';
import 'package:path_provider/path_provider.dart';

class Mp3CacheHandler {
  Future<File?> download(String url, {bool encrypt = false, required String encryptionKey, required String trackId}) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;

      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/audio_cache/mp3_$trackId.mp3';
      final file = File(filePath);
      await file.parent.create(recursive: true);

      if (encrypt) {
        final aes = AESHelper(encryptionKey);
        final encrypted = aes.encryptData(response.bodyBytes);
        await file.writeAsBytes(encrypted);
      } else {
        await file.writeAsBytes(response.bodyBytes);
      }

      return file;
    } catch (e) {
      print('Error downloading MP3 track: $e');
      return null;
    }
  }
}
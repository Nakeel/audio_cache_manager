import 'dart:typed_data' show Uint8List;
import 'package:encrypt/encrypt.dart' as encrypt;

class AESHelper {
  final encrypt.Key _key;
  final encrypt.IV _iv;

  AESHelper(String key)
      : _key = encrypt.Key.fromUtf8(key.padRight(32, '\0')),
        _iv = encrypt.IV.fromLength(16);

  List<int> encryptData(List<int> data) {
    final encrypter = encrypt.Encrypter(encrypt.AES(_key));
    final encrypted = encrypter.encryptBytes(data, iv: _iv);
    return [..._iv.bytes, ...encrypted.bytes];
  }

  List<int> decryptData(List<int> data) {
    final iv = encrypt.IV(Uint8List.fromList(data.sublist(0, 16)));
    final encryptedData = data.sublist(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(_key));
    return encrypter.decryptBytes(encrypt.Encrypted(Uint8List.fromList(encryptedData)), iv: iv);
  }
}
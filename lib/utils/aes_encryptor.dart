import 'dart:typed_data' show Uint8List;

import 'package:encrypt/encrypt.dart' as encrypt;

class AESHelper {
  static final _key = encrypt.Key.fromLength(32);
  static final _iv = encrypt.IV.fromLength(16);
  static final _encrypter = encrypt.Encrypter(encrypt.AES(_key));

  static List<int> encryptData(List<int> data) {
    final encrypted = _encrypter.encryptBytes(data, iv: _iv);
    return encrypted.bytes;
  }

  static List<int> decryptData(List<int> data) {
    final decrypted = _encrypter.decryptBytes(
      encrypt.Encrypted(Uint8List.fromList(data)),
      iv: _iv,
    );
    return decrypted;
  }
}
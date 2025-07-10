
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' show AES, Encrypted, Encrypter, IV, Key;

final Key _encryptionKey = Key.fromLength(32); // 256-bit key
final IV _initializationVector = IV.fromLength(16); // 128-bit IV
class AESHelper {
  static final Encrypter _encrypter = Encrypter(AES(_encryptionKey));

  static Uint8List encrypt(Uint8List plainBytes) {
    final Encrypted encrypted = _encrypter.encryptBytes(plainBytes, iv: _initializationVector);
    return encrypted.bytes;
  }

  static Uint8List decrypt(Uint8List encryptedBytes) {
    final Encrypted encrypted = Encrypted(encryptedBytes);
    final Uint8List decrypted = Uint8List.fromList(_encrypter.decryptBytes(encrypted, iv: _initializationVector));
    return decrypted;
  }
}
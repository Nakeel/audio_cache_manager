
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' show AES, Encrypted, Encrypter, IV, Key;
import 'package:crypto/crypto.dart';

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

  /// NEW: Calculates the SHA-256 hash of the given Uint8List.
  static String calculateSha256(Uint8List bytes) {
    final Digest digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// NEW: Verifies the integrity of the given bytes by comparing its SHA-256 hash
  /// with an expected hash.
  static bool verifyIntegrity(Uint8List bytes, String expectedHash) {
    final String calculatedHash = calculateSha256(bytes);
    return calculatedHash == expectedHash;
  }
}
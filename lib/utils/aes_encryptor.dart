// lib/utils/aes_encryptor.dart
import 'dart:typed_data' show Uint8List;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'dart:convert'; // For utf8 encoding

class AESHelper {
  // IMPORTANT: The encryption key should NOT be hardcoded here.
  // It should be loaded securely at runtime, e.g., from flutter_secure_storage.
  // For demonstration, we'll use a placeholder.
  static String? _currentEncryptionKey;

  // Set the encryption key at runtime (e.g., from your init method in AudioCacheManager)
  static void setEncryptionKey(String key) {
    if (key.length != 32) { // AES-256 requires a 32-byte (256-bit) key
      throw ArgumentError('Encryption key must be 32 bytes (256 bits) long.');
    }
    _currentEncryptionKey = key;
  }

  static Uint8List encryptData(Uint8List data) {
    if (_currentEncryptionKey == null) {
      throw StateError('Encryption key has not been set. Call AESHelper.setEncryptionKey() first.');
    }

    final keyBytes = utf8.encode(_currentEncryptionKey!);
    final key = encrypt.Key(keyBytes);

    // Generate a new, random IV for each encryption operation.
    // IV must be 16 bytes (128 bits) for AES.
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(key));

    final encrypted = encrypter.encryptBytes(data, iv: iv);

    // Prepend the IV to the encrypted data so it can be retrieved during decryption.
    // This is a common practice.
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  static Uint8List decryptData(Uint8List encryptedDataWithIv) {
    if (_currentEncryptionKey == null) {
      throw StateError('Encryption key has not been set. Call AESHelper.setEncryptionKey() first.');
    }
    if (encryptedDataWithIv.length < 16) {
      throw ArgumentError('Invalid encrypted data: too short for IV.');
    }

    final keyBytes = utf8.encode(_currentEncryptionKey!);
    final key = encrypt.Key(keyBytes);

    // Extract IV from the beginning of the encrypted data
    final iv = encrypt.IV(encryptedDataWithIv.sublist(0, 16));
    final encryptedData = encryptedDataWithIv.sublist(16); // The actual encrypted content

    final encrypter = encrypt.Encrypter(encrypt.AES(key));

    final decrypted = encrypter.decryptBytes(
      encrypt.Encrypted(encryptedData),
      iv: iv,
    );
    return Uint8List.fromList(decrypted);
  }
}
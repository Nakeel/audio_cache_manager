// lib/data/services/mp3_cache_handler.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class Mp3CacheHandler {
  late String _cacheDirPath;
  final Dio _dio = Dio();
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    _cacheDirPath = '${appDocDir.path}/audio_cache';
    final cacheDir = Directory(_cacheDirPath);
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    _isInitialized = true;
    AppLogger.info('Mp3CacheHandler initialized. Cache directory: $_cacheDirPath');
  }

  String get cacheDirPath => _cacheDirPath; // Expose the cache directory path

  // Helper to get a unique filename for the track
  String _getFileName(String url, String trackId) {
    // Sanitize trackId to be a valid filename for the file system
    final sanitizedTrackId = trackId.replaceAll(RegExp(r'[^\w\s.-]'), '_'); // Replace invalid chars with underscore
    // Using a fixed extension for MP3s
    return '$sanitizedTrackId.mp3';
  }

  /// Downloads and caches an MP3 file. Returns the local path and file size.
  Future<Map<String, dynamic>?> cacheAudio(
      String remoteUrl,
      String cacheBaseDirPath, // This is now directly the base cache directory
          {
        Function(int received, int total)? onProgress,
        bool encrypt = false, // New parameter for encryption
      }) async {
    if (!_isInitialized) {
      AppLogger.warning('Mp3CacheHandler is not initialized.');
      return null;
    }

    // Using the originalUrl.hashCode as part of the filename to ensure uniqueness for different URLs
    // while still keeping it deterministic. The trackId might not be unique across different URLs.
    final String fileName = _getFileName(remoteUrl, remoteUrl.hashCode.toString());
    final String tempFilePath = '$cacheBaseDirPath/$fileName.tmp';
    final String finalFilePath = '$cacheBaseDirPath/$fileName';

    try {
      AppLogger.info('Downloading MP3 from $remoteUrl to temporary file: $tempFilePath');
      await _dio.download(
        remoteUrl,
        tempFilePath,
        onReceiveProgress: onProgress,
        options: Options(responseType: ResponseType.bytes), // Ensure response is bytes
      );

      final File tempFile = File(tempFilePath);
      if (!await tempFile.exists()) {
        AppLogger.error('Temporary downloaded file does not exist: $tempFilePath');
        return null;
      }

      Uint8List fileBytes = await tempFile.readAsBytes();
      final int originalFileSize = fileBytes.length; // Store original size before encryption

      // --- ENCRYPTION LOGIC ---
      if (encrypt) {
        AppLogger.info('Encrypting audio for $remoteUrl');
        fileBytes = AESHelper.encrypt(fileBytes); // Encrypt the bytes
      }
      // --- END ENCRYPTION LOGIC ---

      final File finalFile = File(finalFilePath);
      await finalFile.writeAsBytes(fileBytes); // Write encrypted or unencrypted bytes

      AppLogger.info('MP3 $fileName saved to $finalFilePath, size: ${fileBytes.length} bytes (Original: $originalFileSize bytes). Encrypted: $encrypt');
      await tempFile.delete(); // Delete temporary file

      return {
        'localPath': finalFilePath,
        'fileSize': fileBytes.length, // Return the size of the written file (encrypted size if encrypted)
        // If original size is critical for validation later, you might store it here as well
      };
    } catch (e, st) {
      AppLogger.error('Error downloading or saving MP3: $e', error: e, stackTrace: st);
      // Clean up temporary file if an error occurs
      final tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      return null;
    }
  }

// No specific dispose needed for Dio or file system operations here.
// The cache directory is managed by AudioCacheManager's cleanup.
}
// lib/data/services/mp3_cache_handler.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;


class Mp3CacheHandler {
  late String _cacheDirPath;
  final Dio _dio = Dio();
  bool _isInitialized = false;

  Future<void> init(String baseCacheDirPath) async {
    if (_isInitialized) return;
    _cacheDirPath = baseCacheDirPath; // Use the provided base path
    final cacheDir = Directory(_cacheDirPath);
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    _isInitialized = true;
    AppLogger.info('Mp3CacheHandler initialized. Cache directory: $_cacheDirPath', name: 'Mp3CacheHandler');
  }

  String get cacheDirPath => _cacheDirPath;

  // Helper to get a unique filename for the track
  String _getFileName(String url, String trackId) {
    // Sanitize trackId to be a valid filename for the file system
    final sanitizedTrackId = trackId.replaceAll(RegExp(r'[^\\w\\s.-]'), '_'); // Replace invalid chars with underscore
    // Using a fixed extension for MP3s
    return 'mp3_$sanitizedTrackId.mp3';
  }

  /// Downloads and caches an MP3 file. Returns the local path and file size.
  Future<Map<String, dynamic>?> cacheAudio(
      String remoteUrl,
      String trackId, {
        Function(int received, int total)? onProgress,
        bool encrypt = false,
      }) async {
    if (!_isInitialized) {
      AppLogger.error('Mp3CacheHandler not initialized.', name: 'Mp3CacheHandler');
      return null;
    }

    // Declare variables outside try block to ensure scope for finally/catch
    final String trackSpecificCacheDirPath = p.join(_cacheDirPath, trackId);
    final Directory trackSpecificCacheDir = Directory(trackSpecificCacheDirPath);
    final String tempFileName = _getFileName(remoteUrl, trackId) + '.tmp';
    final String finalFileName = _getFileName(remoteUrl, trackId);
    final String tempFilePath = p.join(trackSpecificCacheDirPath, tempFileName);
    final String finalFilePath = p.join(trackSpecificCacheDirPath, finalFileName);

    try {
      if (!await trackSpecificCacheDir.exists()) {
        await trackSpecificCacheDir.create(recursive: true);
        AppLogger.info('Created MP3 track cache directory: ${trackSpecificCacheDir.path}', name: 'Mp3CacheHandler');
      }

      AppLogger.info('Downloading MP3 from $remoteUrl to temporary file: $tempFilePath', name: 'Mp3CacheHandler');

      await _dio.download(
        remoteUrl,
        tempFilePath,
        onReceiveProgress: (received, total) {
          onProgress?.call(received, total);
        },
        options: Options(responseType: ResponseType.bytes),
      );

      final tempFile = File(tempFilePath);
      if (!await tempFile.exists()) {
        AppLogger.error('Temporary file not created after download: $tempFilePath', name: 'Mp3CacheHandler');
        return null;
      }

      Uint8List fileBytes = await tempFile.readAsBytes();
      final int originalFileSize = fileBytes.length; // Store original size before encryption

      // --- ENCRYPTION LOGIC ---
      if (encrypt) {
        AppLogger.info('Encrypting audio for $remoteUrl', name: 'Mp3CacheHandler');
        fileBytes = AESHelper.encrypt(fileBytes); // Encrypt the bytes
      }
      // --- END ENCRYPTION LOGIC ---

      final File finalFile = File(finalFilePath);
      await finalFile.writeAsBytes(fileBytes); // Write encrypted or unencrypted bytes

      AppLogger.info('MP3 $finalFileName saved to $finalFilePath, size: ${fileBytes.length} bytes (Original: $originalFileSize bytes). Encrypted: $encrypt', name: 'Mp3CacheHandler');
      await tempFile.delete(); // Delete temporary file

      return {
        'localPath': finalFilePath,
        'fileSize': fileBytes.length, // Return the size of the written file (encrypted size if encrypted)
        // If original size is critical for validation later, you might store it here as well
      };
    } catch (e, st) {
      AppLogger.error('Error downloading or saving MP3: $e', error: e, stackTrace: st, name: 'Mp3CacheHandler');
      // Clean up temporary file if an error occurs
      final tempFile = File(tempFilePath); // Now tempFilePath is in scope
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      // Ensure the newly created track-specific directory is also cleaned up if empty
      if (await trackSpecificCacheDir.exists()) {
        final List<FileSystemEntity> contents = trackSpecificCacheDir.listSync(recursive: false);
        if (contents.isEmpty) { // Only delete if it's empty
          await trackSpecificCacheDir.delete();
          AppLogger.info('Cleaned up empty MP3 track directory: ${trackSpecificCacheDir.path}', name: 'Mp3CacheHandler');
        }
      }
      return null;
    }
  }

// No specific dispose needed for Dio or file system operations here.
// The cache directory is managed by AudioCacheManager's cleanup.
}
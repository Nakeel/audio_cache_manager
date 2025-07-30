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

  /// Downloads and caches an MP3 file.
  /// Returns a map containing 'localPath' and 'fileSize' if successful, null otherwise.
  Future<Map<String, dynamic>?> cacheAudio(
      String mp3Url,
      String trackId, {
        Function(int received, int total)? onProgress,
        bool encrypt = false,
      }) async {
    AppLogger.info('Attempting to cache MP3: $mp3Url for track $trackId. Encrypt: $encrypt', name: 'Mp3CacheHandler');

    final String fileName = _getFileName(mp3Url, trackId);
    final String trackSpecificCacheDirPath = p.join(_cacheDirPath, trackId);
    final Directory trackSpecificCacheDir = Directory(trackSpecificCacheDirPath);
    final String tempFilePath = p.join(trackSpecificCacheDirPath, '$fileName.temp');
    final String finalFilePath = p.join(trackSpecificCacheDirPath, fileName);

    try {
      if (!await trackSpecificCacheDir.exists()) {
        await trackSpecificCacheDir.create(recursive: true);
        AppLogger.info('Created track-specific cache directory: ${trackSpecificCacheDir.path}', name: 'Mp3CacheHandler');
      }

      // Check if the final file already exists and is complete
      final File finalFile = File(finalFilePath);
      if (await finalFile.exists()) {
        final Uint8List cachedBytes = await finalFile.readAsBytes();
        // If encrypted, we can't directly hash the raw bytes on disk for integrity.
        // The integrity check for encrypted files will happen in LocalProxyServer after decryption.
        // For unencrypted, we can check here.
        if (!encrypt) {
          final String calculatedHash = AESHelper.calculateSha256(cachedBytes);
          // Assuming you have a way to retrieve the expected hash (e.g., from metadata store)
          // For now, we'll just log that it exists. Full integrity check is on playback.
          AppLogger.info('MP3 $finalFilePath already exists and will be used.', name: 'Mp3CacheHandler');
          return {
            'localPath': finalFilePath,
            'fileSize': cachedBytes.length,
            'dataHash': calculatedHash, // Return hash for unencrypted, if needed
          };
        } else {
          AppLogger.info('Encrypted MP3 $finalFilePath already exists. Integrity check deferred to proxy.', name: 'Mp3CacheHandler');
          return {
            'localPath': finalFilePath,
            'fileSize': cachedBytes.length,
            'dataHash': null, // Hash will be calculated after decryption in proxy
          };
        }
      }

      // Download to a temporary file first
      AppLogger.info('Downloading MP3 to temporary file: $tempFilePath', name: 'Mp3CacheHandler');
      await _dio.download(
        mp3Url,
        tempFilePath,
        onReceiveProgress: (received, total) {
          if (onProgress != null) {
            onProgress(received, total);
          }
        },
      );
      AppLogger.info('MP3 downloaded to temporary file: $tempFilePath', name: 'Mp3CacheHandler');

      Uint8List fileBytes = await File(tempFilePath).readAsBytes();
      final int originalFileSize = fileBytes.length;
      String? dataHash;

      // Calculate hash of the original (decrypted) content
      dataHash = AESHelper.calculateSha256(fileBytes);
      AppLogger.info('Calculated SHA-256 hash of original content: $dataHash', name: 'Mp3CacheHandler');

      if (encrypt) {
        AppLogger.info('Encrypting MP3 file: $finalFilePath', name: 'Mp3CacheHandler');
        fileBytes = AESHelper.encrypt(fileBytes); // Encrypt the bytes
      }

      // Move from temporary to final path
      await File(tempFilePath).rename(finalFilePath);

      AppLogger.info('MP3  saved to $finalFilePath, size: ${fileBytes.length} bytes (Original: $originalFileSize bytes). Encrypted: $encrypt', name: 'Mp3CacheHandler');

      return {
        'localPath': finalFilePath,
        'fileSize': fileBytes.length, // Return the size of the written file (encrypted size if encrypted)
        'dataHash': dataHash, // Store the hash of the original (decrypted) content
      };
    } catch (e, st) {
      AppLogger.error('Error downloading or saving MP3: $e', error: e, stackTrace: st, name: 'Mp3CacheHandler');
      // Clean up temporary file if an error occurs
      final File tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      // Ensure the newly created track-specific directory is also cleaned up if empty
      if (await trackSpecificCacheDir.exists()) {
        final List<FileSystemEntity> contents = trackSpecificCacheDir.listSync(recursive: false);
        if (contents.isEmpty) {
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
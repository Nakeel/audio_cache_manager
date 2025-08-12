// lib/data/services/mp3_cache_handler.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/aes_encryptor.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;


class Mp3CacheHandler {
  late String _cacheDirPath;
  final Dio _dio = Dio();
  final CacheMetadataStore _metadataStore;

  Mp3CacheHandler({required String cacheDirPath, required CacheMetadataStore metadataStore})
      : _cacheDirPath = cacheDirPath,
        _metadataStore = metadataStore;

  // Helper to get a unique filename for the track
  String _getFileName(String trackId) {
    // Sanitize trackId to be a valid filename for the file system
    final sanitizedTrackId = trackId.replaceAll(RegExp(r'[^\\w\\s.-]'), '_');
    return 'mp3_$sanitizedTrackId.mp3';
  }

  /// Downloads and caches an MP3 stream.
  Future<CacheEntry?> cacheMp3({
    required String url,
    required String cacheBaseDirPath,
    required String trackId,
    Function(int received, int total)? onProgress,
    bool encrypt = false,
  }) async {
    final String trackSpecificCacheDirPath = p.join(cacheBaseDirPath, 'mp3_$trackId');
    final Directory trackSpecificCacheDir = Directory(trackSpecificCacheDirPath);

    // Create the directory if it doesn't exist
    if (!await trackSpecificCacheDir.exists()) {
      await trackSpecificCacheDir.create(recursive: true);
    }

    final String finalFileName = _getFileName(trackId);
    final String finalFilePath = p.join(trackSpecificCacheDir.path, finalFileName);

    try {
      AppLogger.info('Attempting to download and cache MP3: $url for track $trackId', name: 'Mp3CacheHandler');

      final Response response = await _dio.get(
        url,
        onReceiveProgress: (received, total) {
          if (total != -1 && onProgress != null) {
            onProgress(received, total);
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );

      final int originalFileSize = response.data.length;
      Uint8List fileBytes = Uint8List.fromList(response.data);

      if (encrypt) {
        fileBytes = AESHelper.encrypt(fileBytes);
        AppLogger.info('MP3 encrypted successfully.', name: 'Mp3CacheHandler');
      }

      await File(finalFilePath).writeAsBytes(fileBytes);
      AppLogger.info('MP3 saved to $finalFilePath, size: ${fileBytes.length} bytes (Original: $originalFileSize bytes). Encrypted: $encrypt', name: 'Mp3CacheHandler');

      final CacheEntry entry = CacheEntry(
        trackId: trackId,
        originalUrl: url,
        filePath: finalFilePath,
        timestamp: DateTime.now(),
        fileSize: fileBytes.length,
        isEncrypted: encrypt,
        etag: response.headers.value('etag') ?? '',
        lastModified: response.headers.value('last-modified') ?? '',
        contentType: response.headers.value('content-type') ?? 'audio/mpeg',
        proxyUrl: '',
        isHls: false,
      );

      await _metadataStore.save(entry);
      AppLogger.info('Saved cache entry for MP3 track $trackId.', name: 'Mp3CacheHandler');
      return entry;

    } catch (e, st) {
      AppLogger.error('Error downloading or saving MP3: $e', error: e, stackTrace: st, name: 'Mp3CacheHandler');
      // Clean up the directory on error
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
}

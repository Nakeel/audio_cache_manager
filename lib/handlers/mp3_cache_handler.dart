

import 'dart:typed_data';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:dio/dio.dart';

class Mp3CacheHandler {
  final Dio _dio = Dio();

  /// Downloads MP3 bytes with progress tracking.
  /// Returns null if download fails or is incomplete.
  Future<Uint8List?> downloadMp3Bytes(
      String url, {
        Function(int received, int total)? onProgress,
      }) async {
    try {
      Response<Uint8List> response = await _dio.get<Uint8List>(
        url,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (onProgress != null && total != -1) {
            onProgress(received, total);
          }
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        if (onProgress != null) {
          // Ensure final progress is reported as 100%
          onProgress(response.data!.length, response.data!.length);
        }
        AppLogger.info('Successfully downloaded MP3 from $url. Size: ${response.data!.length} bytes');
        return response.data;
      } else {
        AppLogger.warning('Failed to download MP3 from $url. Status: ${response.statusCode}');
        return null;
      }
    } on DioException catch (e, st) {
      AppLogger.error('DioError downloading MP3 from $url: ${e.message}', error: e, stackTrace: st);
      return null;
    } catch (e, st) {
      AppLogger.error('Error downloading MP3 from $url: $e', error: e, stackTrace: st);
      return null;
    }
  }
}
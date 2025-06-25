import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show Dio, DioException, Options, ResponseType;
import 'package:http/http.dart' as http;
import '../utils/aes_encryptor.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:typed_data';

class Mp3CacheHandler {
  final Dio _dio = Dio(); // Use Dio for better download control

  /// Downloads an MP3 file from the given URL.
  /// Returns the raw bytes of the downloaded file.
  Future<Uint8List?> downloadMp3Bytes(String url, {Function(int received, int total)? onProgress}) async {
    try {
      final response = await _dio.get<Uint8List>(
        url,
        options: Options(responseType: ResponseType.bytes), // Ensure response is bytes
        onReceiveProgress: onProgress,
      );

      if (response.statusCode == 200 && response.data != null) {
        return response.data;
      } else {
        print('Failed to download MP3 from $url. Status: ${response.statusCode}');
        return null;
      }
    } on DioException catch (e) {
      print('DioError downloading MP3 from $url: ${e.message}');
      return null;
    } catch (e) {
      print('Error downloading MP3 from $url: $e');
      return null;
    }
  }

  /// Encrypts the given MP3 data.
  Uint8List encryptMp3Data(Uint8List data) {
    return AESHelper.encryptData(data);
  }
}
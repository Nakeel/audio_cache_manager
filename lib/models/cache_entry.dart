import 'dart:io';
import 'package:hive/hive.dart';

part 'cache_entry.g.dart';

@HiveType(typeId: 178)
class CacheEntry extends HiveObject {
  @HiveField(0)
  final String trackId;

  @HiveField(1)
  final String originalUrl;

  @HiveField(2)
  final String? filePath;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final int fileSize;

  @HiveField(5)
  final bool isEncrypted;

  @HiveField(6)
  final String? etag;

  @HiveField(7)
  final String? lastModified;

  @HiveField(8)
  final String? contentType;

  @HiveField(9)
  final String? proxyUrl;

  @HiveField(10)
  final bool isHls;

  @HiveField(11)
  final String? hlsLocalPath;

  @HiveField(12)
  final String? hlsManifestFilePath;

  CacheEntry({
    required this.trackId,
    required this.originalUrl,
    this.filePath,
    required this.timestamp,
    required this.fileSize,
    required this.isEncrypted,
    this.etag,
    this.lastModified,
    this.contentType,
    this.proxyUrl,
    this.isHls = false,
    this.hlsLocalPath,
    this.hlsManifestFilePath,
  });

  CacheEntry copyWith({
    String? trackId,
    String? originalUrl,
    String? filePath,
    DateTime? timestamp,
    int? fileSize,
    bool? isEncrypted,
    String? etag,
    String? lastModified,
    String? contentType,
    String? proxyUrl,
    bool? isHls,
    String? hlsLocalPath,
    String? hlsManifestFilePath,
  }) {
    return CacheEntry(
      trackId: trackId ?? this.trackId,
      originalUrl: originalUrl ?? this.originalUrl,
      filePath: filePath ?? this.filePath,
      timestamp: timestamp ?? this.timestamp,
      fileSize: fileSize ?? this.fileSize,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      etag: etag ?? this.etag,
      lastModified: lastModified ?? this.lastModified,
      contentType: contentType ?? this.contentType,
      proxyUrl: proxyUrl ?? this.proxyUrl,
      isHls: isHls ?? this.isHls,
      hlsLocalPath: hlsLocalPath ?? this.hlsLocalPath,
      hlsManifestFilePath: hlsManifestFilePath ?? this.hlsManifestFilePath,
    );
  }

  FileSystemEntity get cacheFileEntity {
    if (isHls && hlsLocalPath != null) {
      return Directory(hlsLocalPath!);
    }
    return File(filePath!);
  }
}

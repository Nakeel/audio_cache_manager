
import 'dart:io';
import 'package:hive/hive.dart';

part 'hls_segment_entry.g.dart';
// NEW FILE: lib/models/hls_segment_entry.dart
// This needs to be a separate file because Hive `part` directives are file-specific.
// You'll need to create a new file named `hls_segment_entry.dart` in your `models` directory.
@HiveType(typeId: 179) // Assign a new unique typeId
class HlsSegmentEntry extends HiveObject {
  @HiveField(0)
  final String originalUrl; // Original full URL of the segment

  @HiveField(1)
  final String localRelativePath; // Path relative to hlsLocalPath

  @HiveField(2)
  int downloadedBytes; // Bytes downloaded so far

  @HiveField(3)
  int totalBytes; // Total bytes of the segment (0 if unknown)

  @HiveField(4)
  bool isComplete; // True if fully downloaded and verified

  HlsSegmentEntry({
    required this.originalUrl,
    required this.localRelativePath,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.isComplete = false,
  });

  HlsSegmentEntry copyWith({
    String? originalUrl,
    String? localRelativePath,
    int? downloadedBytes,
    int? totalBytes,
    bool? isComplete,
  }) {
    return HlsSegmentEntry(
      originalUrl: originalUrl ?? this.originalUrl,
      localRelativePath: localRelativePath ?? this.localRelativePath,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}
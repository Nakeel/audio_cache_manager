// lib/data/models/cached_audio_item.dart
import 'package:hive/hive.dart';

// IMPORTANT: Generate Hive adapter by running `flutter pub run build_runner build`
part 'cached_audio_item.g.dart';

@HiveType(typeId: 0) // Unique typeId for Hive
class CachedAudioItem extends HiveObject {
  @HiveField(0)
  final String trackId; // Unique identifier for the audio track
  @HiveField(1)
  final String originalUrl; // Original URL (MP3 or HLS manifest)
  @HiveField(2)
  final String localPath; // Local path to the cached file (MP3) or directory (HLS)
  @HiveField(3)
  final DateTime downloadedAt; // When it was first downloaded
  @HiveField(4)
  DateTime lastAccessedAt; // When it was last played/accessed (for LRU)
  @HiveField(5)
  final int fileSize; // Total size of the cached content in bytes
  @HiveField(6)
  final bool isEncrypted; // Whether the cached content is encrypted
  @HiveField(7)
  final bool isHls; // Whether it's an HLS stream (true) or an MP3 (false)

  // You can add more metadata fields here, e.g., title, artist, albumArtUrl
  // @HiveField(8)
  // final String? title;
  // @HiveField(9)
  // final String? artist;

  CachedAudioItem({
    required this.trackId,
    required this.originalUrl,
    required this.localPath,
    required this.downloadedAt,
    required this.lastAccessedAt,
    required this.fileSize,
    required this.isEncrypted,
    required this.isHls,
    // this.title,
    // this.artist,
  });

  // Method to update last accessed time
  void updateAccessedTime() {
    lastAccessedAt = DateTime.now();
  }
}

import 'package:hive/hive.dart';

// IMPORTANT: After modifying this file, you MUST re-run:
// `flutter pub run build_runner build --delete-conflicting-outputs`
// to generate the updated `cache_entry.g.dart` file.
part 'cache_entry.g.dart';

@HiveType(typeId: 0) // Unique typeId for Hive
class CacheEntry extends HiveObject {
  @HiveField(0)
  final String trackId; // New: Unique identifier for the audio track (will be Hive key)

  @HiveField(1)
  final String url; // Original URL (MP3 or HLS master manifest)

  @HiveField(2)
  final String localPath; // Local path to the cached file (MP3) or HLS directory

  @HiveField(3)
  final DateTime cachedAt; // When the item was first downloaded

  @HiveField(4)
  DateTime lastAccessedAt; // When the item was last played/accessed (for LRU eviction)

  @HiveField(5)
  final int fileSize; // Total size of the cached content in bytes (file or directory)

  @HiveField(6)
  final bool isEncrypted; // True if the cached content is encrypted

  @HiveField(7)
  final bool isHls; // True if it's an HLS stream, false for MP3

  // You can add more metadata fields here, e.g., title, artist, albumArtUrl
  // @HiveField(8)
  // final String? title;
  // @HiveField(9)
  // final String? artist;

  CacheEntry({
    required this.trackId, // New: Required in constructor
    required this.url,
    required this.localPath,
    required this.cachedAt,
    required this.lastAccessedAt,
    required this.fileSize,
    required this.isEncrypted,
    required this.isHls,
    // this.title,
    // this.artist,
  });

  // Method to update last accessed time (for LRU)
  void updateAccessedTime() {
    lastAccessedAt = DateTime.now();
  }
}
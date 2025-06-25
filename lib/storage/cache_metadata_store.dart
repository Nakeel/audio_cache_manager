import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart'; // No longer strictly needed if Hive.initFlutter is in main()
import '../models/cache_entry.dart';

class CacheMetadataStore {
  late final Box<CacheEntry> _box;

  Future<void> init() async {
    // Hive.initFlutter() and Hive.registerAdapter() should be called ONCE in main()
    if (!Hive.isAdapterRegistered(178)) { // 0 is the typeId for CacheEntry
      Hive.registerAdapter(CacheEntryAdapter());
    }

    _box = await Hive.openBox<CacheEntry>('audio_cache_metadata');
    print('CacheMetadataStore: Cleared old data for refactoring.');
    print('CacheMetadataStore initialized.');
  }

  // Use trackId as the key
  Future<void> save(CacheEntry entry) async {
    await _box.put(entry.trackId, entry); // Save with trackId as key
  }

  // Get by trackId
  Future<CacheEntry?> get(String trackId) async {
    return _box.get(trackId); // Get by trackId
  }

  Future<List<CacheEntry>> getAll() async {
    return _box.values.toList();
  }

  // Delete by trackId
  Future<void> delete(String trackId) async {
    await _box.delete(trackId); // Delete by trackId
  }

  Future<void> clear() async {
    await _box.clear();
  }

  /// Get the current total size of all cached items based on metadata.
  int getCurrentCacheSize() {
    return _box.values.fold(0, (sum, entry) => sum + entry.fileSize);
  }
}
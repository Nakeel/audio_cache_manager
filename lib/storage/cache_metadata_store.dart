import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import '../models/cache_entry.dart';


class CacheMetadataStore {
  Box? _box; // Remove late, make nullable
  bool _isInitialized = false; // Track initialization state

  Future<void> init() async {
    if (_isInitialized) return; // Prevent reinitialization
    try {
      final dir = await getApplicationDocumentsDirectory();
      Hive.init(dir.path);
      _box = await Hive.openBox('audio_cache_metadata');
      _isInitialized = true;
    } catch (e) {
      throw Exception('Failed to initialize cache metadata store: $e');
    }
  }

  Future<void> save(CacheEntry entry) async {
    if (!_isInitialized) await init();
    await _box!.put(entry.url, entry.toMap());
  }

  Future<CacheEntry?> get(String url) async {
    if (!_isInitialized) await init();
    final map = _box!.get(url);
    return map != null ? CacheEntry.fromMap(Map<String, dynamic>.from(map)) : null;
  }

  Future<List<CacheEntry>> getAll() async {
    if (!_isInitialized) await init();
    return _box!.values
        .map((e) => CacheEntry.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> delete(String url) async {
    if (!_isInitialized) await init();
    await _box!.delete(url);
  }

  Future<void> clear() async {
    if (!_isInitialized) await init();
    await _box!.clear();
  }

  Future<void> dispose() async {
    if (_isInitialized) {
      await _box?.close();
      _isInitialized = false;
      _box = null;
    }
  }
}
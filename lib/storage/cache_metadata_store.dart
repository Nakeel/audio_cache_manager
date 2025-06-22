import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import '../models/cache_entry.dart';

class CacheMetadataStore {
  late final Box _box;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    Hive.init(dir.path);
    _box = await Hive.openBox('audio_cache_metadata');
  }

  Future<void> save(CacheEntry entry) async {
    await _box.put(entry.url, entry.toMap());
  }

  Future<CacheEntry?> get(String url) async {
    final map = _box.get(url);
    return map != null ? CacheEntry.fromMap(Map<String, dynamic>.from(map)) : null;
  }

  Future<List<CacheEntry>> getAll() async {
    return _box.values
        .map((e) => CacheEntry.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> delete(String url) async {
    await _box.delete(url);
  }

  Future<void> clear() async {
    await _box.clear();
  }
}
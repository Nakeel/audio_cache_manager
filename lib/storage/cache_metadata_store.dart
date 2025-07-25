// lib/data/cache_metadata_store.dart

import 'package:audio_cache_manager/utils/app_logger.dart';

import '../models/cache_entry.dart';
import 'package:hive_flutter/hive_flutter.dart';

class CacheMetadataStore {
  static const String _boxName = 'audioCacheMetadata';
  late Box<CacheEntry> _box;
  int _currentCacheSize = 0; // To track total size of cached items

  Future<void> init() async {
    if (!Hive.isAdapterRegistered(0)) { // Check if adapter is already registered
      Hive.registerAdapter(CacheEntryAdapter());
    }
    await Hive.initFlutter();
    _box = await Hive.openBox<CacheEntry>(_boxName);
    _calculateInitialSize(); // Calculate size on startup
    AppLogger.info('CacheMetadataStore initialized. Current size: ${_currentCacheSize} bytes');
  }

  void _calculateInitialSize() {
    _currentCacheSize = 0;
    for (final entry in _box.values) {
      _currentCacheSize += entry.fileSize; // <--- Changed from entry.fileSize
    }
  }

  Future<void> save(CacheEntry entry) async {
    final existingEntry = _box.get(entry.trackId);
    if (existingEntry != null) {
      // Adjust current size if replacing an entry
      _currentCacheSize -= existingEntry.fileSize; // <--- Changed from existingEntry.fileSize
    }
    await _box.put(entry.trackId, entry);
    _currentCacheSize += entry.fileSize; // <--- Changed from entry.fileSize
    AppLogger.info('Saved cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes');
  }

  Future<CacheEntry?> get(String trackId) async {
    return _box.get(trackId);
  }

  Future<void> delete(String trackId) async {
    final entry = _box.get(trackId);
    if (entry != null) {
      _currentCacheSize -= entry.fileSize; // <--- Changed from entry.fileSize
      await _box.delete(trackId);
      AppLogger.info('Deleted cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes');
    }
  }

  Future<List<CacheEntry>> getAll() async {
    return _box.values.toList();
  }

  Future<void> clear() async {
    await _box.clear();
    _currentCacheSize = 0;
    AppLogger.info('Cleared all cache metadata. Current total size: $_currentCacheSize bytes');
  }

  int getCurrentCacheSize() {
    return _currentCacheSize;
  }

  Future<void> close() async {
    await _box.close();
  }
}
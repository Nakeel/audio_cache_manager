// lib/data/cache_metadata_store.dart

import 'package:audio_cache_manager/utils/app_logger.dart';
import '../models/cache_entry.dart';
import '../models/hls_segment_entry.dart'; // NEW: Import the new segment entry
import 'package:hive_flutter/hive_flutter.dart';

class CacheMetadataStore {
  static const String _boxName = 'audioCacheMetadata';
  late Box<CacheEntry> _box;
  int _currentCacheSize = 0; // To track total size of cached items

  Future<void> init() async {
    if (!Hive.isAdapterRegistered(178)) { // Check if adapter for CacheEntry is registered
      Hive.registerAdapter(CacheEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(179)) { // NEW: Check if adapter for HlsSegmentEntry is registered
      Hive.registerAdapter(HlsSegmentEntryAdapter());
    }
    await Hive.initFlutter();
    _box = await Hive.openBox<CacheEntry>(_boxName);
    _calculateInitialSize(); // Calculate size on startup
    AppLogger.info('CacheMetadataStore initialized. Current size: ${_currentCacheSize} bytes');
  }

  void _calculateInitialSize() {
    _currentCacheSize = 0;
    for (final entry in _box.values) {
      // For HLS, sum up the downloadedBytes of completed segments, or totalBytes if available.
      // For MP3, use fileSize.
      if (entry.isHls && entry.hlsSegments != null) {
        _currentCacheSize += entry.hlsSegments!
            .where((s) => s.isComplete)
            .fold(0, (sum, s) => sum + s.totalBytes); // Sum of completed segments
      } else {
        _currentCacheSize += entry.fileSize;
      }
    }
  }

  Future<void> save(CacheEntry entry) async {
    final existingEntry = _box.get(entry.trackId);
    if (existingEntry != null) {
      // Adjust current size if replacing an entry
      if (existingEntry.isHls && existingEntry.hlsSegments != null) {
        _currentCacheSize -= existingEntry.hlsSegments!
            .where((s) => s.isComplete)
            .fold(0, (sum, s) => sum + s.totalBytes);
      } else {
        _currentCacheSize -= existingEntry.fileSize;
      }
    }
    await _box.put(entry.trackId, entry);
    // Add new entry's size
    if (entry.isHls && entry.hlsSegments != null) {
      _currentCacheSize += entry.hlsSegments!
          .where((s) => s.isComplete)
          .fold(0, (sum, s) => sum + s.totalBytes);
    } else {
      _currentCacheSize += entry.fileSize;
    }
    AppLogger.info('Saved cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes');
  }

  Future<CacheEntry?> get(String trackId) async {
    return _box.get(trackId);
  }

  Future<void> delete(String trackId) async {
    final entry = _box.get(trackId);
    if (entry != null) {
      if (entry.isHls && entry.hlsSegments != null) {
        _currentCacheSize -= entry.hlsSegments!
            .where((s) => s.isComplete)
            .fold(0, (sum, s) => sum + s.totalBytes);
      } else {
        _currentCacheSize -= entry.fileSize;
      }
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
// lib/data/cache_metadata_store.dart

import 'dart:io' show Directory, File;

import 'package:audio_cache_manager/utils/app_logger.dart';
import '../models/cache_entry.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class CacheMetadataStore {
  static const String _boxName = 'audioCacheMetadata';
  late Box<CacheEntry> _box;
  int _currentCacheSize = 0;

  int get currentCacheSize => _currentCacheSize;

  Future<void> init() async {
    AppLogger.info('Initializing CacheMetadataStore...', name: 'CacheMetadataStore');
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final hiveDir = Directory(p.join(appDocDir.path, 'hive_data'));
      if (!await hiveDir.exists()) {
        await hiveDir.create(recursive: true);
      }
      Hive.init(hiveDir.path);

      if (!Hive.isAdapterRegistered(178)) {
        Hive.registerAdapter(CacheEntryAdapter());
      }
      _box = await Hive.openBox<CacheEntry>(_boxName);
      _calculateInitialSize();
      AppLogger.info('CacheMetadataStore initialized. Current size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
    } catch (e, st) {
      AppLogger.error('Error initializing CacheMetadataStore: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
    }
  }

  void _calculateInitialSize() {
    _currentCacheSize = 0;
    for (final entry in _box.values) {
      // For HLS, we need to calculate the directory size, not just the single file size
      if (entry.isHls && entry.hlsLocalPath != null) {
        _currentCacheSize += _getDirectorySize(Directory(entry.hlsLocalPath!));
      } else {
        _currentCacheSize += entry.fileSize;
      }
    }
  }

  int _getDirectorySize(Directory dir) {
    int totalSize = 0;
    if (dir.existsSync()) {
      dir.listSync(recursive: true).forEach((file) {
        if (file is File) {
          totalSize += file.lengthSync();
        }
      });
    }
    return totalSize;
  }

  Future<void> save(CacheEntry entry) async {
    final existingEntry = _box.get(entry.trackId);
    if (existingEntry != null) {
      _currentCacheSize -= existingEntry.fileSize;
    }
    await _box.put(entry.trackId, entry);
    _currentCacheSize += entry.fileSize;
    AppLogger.info('Saved cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
  }

  CacheEntry? getSync(String trackId) {
    return _box.get(trackId);
  }

  Future<CacheEntry?> get(String trackId) async {
    return _box.get(trackId);
  }

  Future<void> delete(String trackId) async {
    final entry = _box.get(trackId);
    if (entry != null) {
      _currentCacheSize -= entry.fileSize;
      await _box.delete(trackId);
      AppLogger.info('Deleted cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
    }
  }

  Future<List<CacheEntry>> getAll() async {
    return _box.values.toList();
  }

  Future<void> clear() async {
    AppLogger.info('Clearing all cache metadata...', name: 'CacheMetadataStore');
    await _box.clear();
    _currentCacheSize = 0;
    AppLogger.info('Cache metadata cleared.', name: 'CacheMetadataStore');
  }

  Future<void> close() async {
    AppLogger.info('Closing CacheMetadataStore...', name: 'CacheMetadataStore');
    await _box.close();
    AppLogger.info('CacheMetadataStore closed.', name: 'CacheMetadataStore');
  }
}

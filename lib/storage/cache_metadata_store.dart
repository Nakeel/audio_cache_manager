// // lib/data/cache_metadata_store.dart
//
// import 'package:audio_cache_manager/utils/app_logger.dart';
//
// import '../models/cache_entry.dart';
// import 'package:hive_flutter/hive_flutter.dart';
//
// class CacheMetadataStore {
//   static const String _boxName = 'audioCacheMetadata';
//   late Box<CacheEntry> _box;
//   int _currentCacheSize = 0; // To track total size of cached items
//
//   Future<void> init() async {
//     if (!Hive.isAdapterRegistered(0)) { // Check if adapter is already registered
//       Hive.registerAdapter(CacheEntryAdapter());
//     }
//     await Hive.initFlutter();
//     _box = await Hive.openBox<CacheEntry>(_boxName);
//     _calculateInitialSize(); // Calculate size on startup
//     AppLogger.info('CacheMetadataStore initialized. Current size: ${_currentCacheSize} bytes');
//   }
//
//   void _calculateInitialSize() {
//     _currentCacheSize = 0;
//     for (final entry in _box.values) {
//       _currentCacheSize += entry.fileSize; // <--- Changed from entry.fileSize
//     }
//   }
//
//   Future<void> save(CacheEntry entry) async {
//     final existingEntry = _box.get(entry.trackId);
//     if (existingEntry != null) {
//       // Adjust current size if replacing an entry
//       _currentCacheSize -= existingEntry.fileSize; // <--- Changed from existingEntry.fileSize
//     }
//     await _box.put(entry.trackId, entry);
//     _currentCacheSize += entry.fileSize; // <--- Changed from entry.fileSize
//     AppLogger.info('Saved cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes');
//   }
//
//   Future<CacheEntry?> get(String trackId) async {
//     return _box.get(trackId);
//   }
//
//   Future<void> delete(String trackId) async {
//     final entry = _box.get(trackId);
//     if (entry != null) {
//       _currentCacheSize -= entry.fileSize; // <--- Changed from entry.fileSize
//       await _box.delete(trackId);
//       AppLogger.info('Deleted cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes');
//     }
//   }
//
//   Future<List<CacheEntry>> getAll() async {
//     return _box.values.toList();
//   }
//
//   Future<void> clear() async {
//     await _box.clear();
//     _currentCacheSize = 0;
//     AppLogger.info('Cleared all cache metadata. Current total size: $_currentCacheSize bytes');
//   }
//
//   int getCurrentCacheSize() {
//     return _currentCacheSize;
//   }
//
//   Future<void> close() async {
//     await _box.close();
//   }
// }

import 'dart:io';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/cache_entry.dart';

class CacheMetadataStore {
  static const String _boxName = 'audioCacheMetadata';
  late Box<CacheEntry> _box;
  int _currentCacheSize = 0;

  Future<void> init() async {
    try {
      // Ensure Hive is initialized only once
      if (!Hive.isAdapterRegistered(178)) {
        Hive.registerAdapter(CacheEntryAdapter());
      }
      await Hive.initFlutter();
      _box = await Hive.openBox<CacheEntry>(_boxName);
      await _calculateInitialSize();
      AppLogger.info('CacheMetadataStore initialized. Current size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
    } catch (e, st) {
      AppLogger.error('Error initializing CacheMetadataStore: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
      rethrow;
    }
  }

  Future<void> _calculateInitialSize() async {
    _currentCacheSize = 0;
    for (final entry in _box.values) {
      if (entry.isHls && entry.hlsLocalPath != null) {
        final Directory dir = Directory(entry.hlsLocalPath!);
        if (await dir.exists()) {
          await for (var entity in dir.list(recursive: true)) {
            if (entity is File) {
              _currentCacheSize += await entity.length();
            }
          }
        }
      } else if (entry.filePath.isNotEmpty) {
        final File file = File(entry.filePath);
        if (await file.exists()) {
          _currentCacheSize += await file.length();
        }
      }
    }
    AppLogger.info('Calculated initial cache size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
  }

  Future<void> save(CacheEntry entry) async {
    try {
      final existingEntry = await _box.get(entry.trackId);
      if (existingEntry != null) {
        _currentCacheSize -= existingEntry.fileSize;
      }
      await _box.put(entry.trackId, entry);
      _currentCacheSize += entry.fileSize;
      AppLogger.info('Saved cache entry for ${entry.trackId}. Current total size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
    } catch (e, st) {
      AppLogger.error('Error saving cache entry for ${entry.trackId}: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
    }
  }

  Future<CacheEntry?> get(String trackId) async {
    try {
      final entry = await _box.get(trackId);
      if (entry != null) {
        AppLogger.info('Retrieved cache entry for $trackId: ${entry.toString()}', name: 'CacheMetadataStore');
      }
      return entry;
    } catch (e, st) {
      AppLogger.error('Error retrieving cache entry for $trackId: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
      return null;
    }
  }

  Future<void> delete(String trackId) async {
    try {
      final entry = await _box.get(trackId);
      if (entry != null) {
        _currentCacheSize -= entry.fileSize;
        await _box.delete(trackId);
        AppLogger.info('Deleted cache entry for $trackId. Current total size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
      }
    } catch (e, st) {
      AppLogger.error('Error deleting cache entry for $trackId: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
    }
  }

  Future<List<CacheEntry>> getAll() async {
    try {
      return _box.values.toList();
    } catch (e, st) {
      AppLogger.error('Error retrieving all cache entries: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
      return [];
    }
  }

  Future<void> clear() async {
    try {
      await _box.clear();
      _currentCacheSize = 0;
      AppLogger.info('Cleared all cache metadata. Current total size: $_currentCacheSize bytes', name: 'CacheMetadataStore');
    } catch (e, st) {
      AppLogger.error('Error clearing cache metadata: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
    }
  }

  int getCurrentCacheSize() => _currentCacheSize;

  Future<void> close() async {
    try {
      await _box.close();
      AppLogger.info('CacheMetadataStore closed', name: 'CacheMetadataStore');
    } catch (e, st) {
      AppLogger.error('Error closing CacheMetadataStore: $e', error: e, stackTrace: st, name: 'CacheMetadataStore');
    }
  }
}
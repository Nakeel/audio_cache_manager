import 'dart:io';

import 'package:audio_cache_manager/handlers/hls_cache_handler.dart';
import 'package:audio_cache_manager/handlers/local_proxy_server.dart';
import 'package:audio_cache_manager/handlers/mp3_cache_handler.dart';
import 'package:audio_cache_manager/models/cache_entry.dart';
import 'package:audio_cache_manager/storage/cache_metadata_store.dart';
import 'package:audio_cache_manager/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;

  AudioCacheManager._internal();

  late String _cacheDirPath;
  late CacheMetadataStore _metadataStore;
  late LocalProxyServer _proxyServer;
  late Mp3CacheHandler _mp3CacheHandler;
  late HlsCacheHandler _hlsCacheHandler;

  bool _isInitialized = false;
  Duration _expirationDuration = const Duration(days: 30);
  int _maxCacheSizeBytes = 500 * 1024 * 1024; // Default 500 MB

  bool get isInitialized => _isInitialized;
  String get cacheDirPath => _cacheDirPath;
  int get proxyPort => _proxyServer.port;

  Future<void> init() async {
    if (_isInitialized) {
      AppLogger.warning('AudioCacheManager already initialized.', name: 'AudioCacheManager');
      return;
    }

    AppLogger.info('Initializing AudioCacheManager...', name: 'AudioCacheManager');
    _cacheDirPath = await _getCacheDirPath();

    // Initialize metadata store
    _metadataStore = CacheMetadataStore();
    await _metadataStore.init();

    // Initialize proxy server
    _proxyServer = LocalProxyServer(cacheDirPath: _cacheDirPath, metadataStore: _metadataStore);
    await _proxyServer.start();

    // Initialize handlers
    _mp3CacheHandler = Mp3CacheHandler(cacheDirPath: _cacheDirPath, metadataStore: _metadataStore);
    _hlsCacheHandler = HlsCacheHandler(
      proxyServer: _proxyServer,
      metadataStore: _metadataStore,
    );

    _isInitialized = true;
    AppLogger.info('AudioCacheManager initialized successfully. Cache directory: $_cacheDirPath, Proxy port: $_proxyServer.port', name: 'AudioCacheManager');
  }

  /// Caches an audio file (MP3 or HLS) and returns a [CacheEntry] with its local path.
  Future<CacheEntry?> cacheAudio({
    required String url,
    required String trackId,
    required bool isHls,
    bool encrypt = false,
  }) async {
    if (!_isInitialized) {
      AppLogger.warning('AudioCacheManager not initialized. Cannot cache audio.', name: 'AudioCacheManager');
      return null;
    }

    AppLogger.info('Caching audio for trackId: $trackId, URL: $url', name: 'AudioCacheManager');

    if (isHls) {
      return _hlsCacheHandler.cacheHls(
        hlsUrl: url,
        cacheBaseDirPath: _cacheDirPath,
        trackId: trackId,
        encrypt: encrypt,
      );
    } else {
      return _mp3CacheHandler.cacheMp3(
        url: url,
        cacheBaseDirPath: _cacheDirPath,
        trackId: trackId,
        encrypt: encrypt,
      );
    }
  }

  /// Retrieves a cached audio entry by its ID.
  Future<CacheEntry?> getCachedAudio(String trackId) async {
    final CacheEntry? entry = await _metadataStore.get(trackId);
    if (entry != null && await entry.cacheFileEntity.exists()) {
      AppLogger.info('Found cached audio for trackId: $trackId', name: 'AudioCacheManager');
      // Update last accessed time for LRU policy
      await _metadataStore.save(entry.copyWith(timestamp: DateTime.now()));
      return entry;
    }
    AppLogger.info('No cached audio found for trackId: $trackId', name: 'AudioCacheManager');
    return null;
  }

  /// Deletes a cached audio entry.
  Future<void> deleteCachedAudio(String trackId) async {
    final entry = await _metadataStore.get(trackId);
    if (entry == null) {
      AppLogger.info('No cached entry to delete for trackId: $trackId', name: 'AudioCacheManager');
      return;
    }

    AppLogger.info('Deleting cached audio for trackId: $trackId', name: 'AudioCacheManager');
    if (entry.isHls && entry.hlsLocalPath != null) {
      await _hlsCacheHandler.deleteCachedHls(entry.hlsLocalPath!);
    } else if (entry.filePath != null) {
      final file = File(entry.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await _metadataStore.delete(trackId);
    AppLogger.info('Successfully deleted cached audio for trackId: $trackId', name: 'AudioCacheManager');
  }

  Future<void> _pruneCache() async {
    AppLogger.info('Pruning cache based on size and expiration...', name: 'AudioCacheManager');
    final allEntries = await _metadataStore.getAll();
    allEntries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final expiredEntries = allEntries.where((entry) =>
    DateTime.now().difference(entry.timestamp) > _expirationDuration).toList();

    for (final entry in expiredEntries) {
      await deleteCachedAudio(entry.trackId);
    }

    while (_metadataStore.currentCacheSize > _maxCacheSizeBytes && _metadataStore.currentCacheSize > 0) {
      if (allEntries.isEmpty) break;
      final oldestEntry = allEntries.removeAt(0);
      AppLogger.info('Cache size ${_metadataStore.currentCacheSize} exceeds limit. Deleting oldest entry: ${oldestEntry.trackId}', name: 'AudioCacheManager');
      await deleteCachedAudio(oldestEntry.trackId);
    }
    AppLogger.info('Cache pruning complete. Current size: ${(_metadataStore.currentCacheSize / (1024 * 1024)).toStringAsFixed(2)} MB', name: 'AudioCacheManager');
  }

  Future<String> _getCacheDirPath() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(appDocDir.path, 'audio_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  void dispose() {
    if (_isInitialized) {
      _proxyServer.stop();
      _metadataStore.close();
      _isInitialized = false;
      AppLogger.info('AudioCacheManager disposed.', name: 'AudioCacheManager');
    }
  }

  void setMaxCacheSize(int bytes) {
    if (bytes < 0) {
      AppLogger.warning('Max cache size cannot be negative. Setting to 0.', name: 'AudioCacheManager');
      _maxCacheSizeBytes = 0;
    } else {
      _maxCacheSizeBytes = bytes;
      AppLogger.info('Max cache size set to ${(_maxCacheSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB', name: 'AudioCacheManager');
    }
  }

  int getMaxCacheSize() => _maxCacheSizeBytes;

  void setExpirationDuration(Duration duration) {
    if (duration.isNegative) {
      AppLogger.warning('Expiration duration cannot be negative. Setting to 0.', name: 'AudioCacheManager');
      _expirationDuration = Duration.zero;
    } else {
      _expirationDuration = duration;
      AppLogger.info('Expiration duration set to ${duration.inDays} days', name: 'AudioCacheManager');
    }
  }
}

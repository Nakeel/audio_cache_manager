import 'dart:io' show File;

import 'package:audio_cache_manager/storage/cache_metadata_store.dart' show CacheMetadataStore;

import '../handlers/hls_cache_handler.dart' show HlsCacheHandler;
import '../handlers/mp3_cache_handler.dart' show Mp3CacheHandler;
import '../models/cache_entry.dart' show CacheEntry;

class AudioCacheManager {
  final Duration expirationDuration;
  final bool enableEncryption;
  final bool useLocalHttpServer;

  final Mp3CacheHandler _mp3Handler;
  final HlsCacheHandler _hlsHandler;
  final CacheMetadataStore _metadataStore;

  AudioCacheManager({
    this.expirationDuration = const Duration(days: 7),
    this.enableEncryption = false,
    this.useLocalHttpServer = true,
  })  : _metadataStore = CacheMetadataStore(),
        _mp3Handler = Mp3CacheHandler(),
        _hlsHandler = HlsCacheHandler();

  Future<void> init() async {
    await _metadataStore.init();
    await _cleanupExpiredCache();
    if (useLocalHttpServer) await _hlsHandler.startServer();
  }

  Future<File?> getAudioFile(String url, {bool isHls = false}) async {
    final now = DateTime.now();
    final entry = await _metadataStore.get(url);

    if (entry != null && now.difference(entry.cachedAt) < expirationDuration) {
      return File(entry.localPath);
    }

    File? downloadedFile;
    if (isHls) {
      downloadedFile = await _hlsHandler.download(url, encrypt: enableEncryption);
    } else {
      downloadedFile = await _mp3Handler.download(url, encrypt: enableEncryption);
    }

    if (downloadedFile != null) {
      await _metadataStore.save(CacheEntry(
        url: url,
        localPath: downloadedFile.path,
        cachedAt: now,
      ));
    }

    return downloadedFile;
  }

  Future<void> _cleanupExpiredCache() async {
    final allEntries = await _metadataStore.getAll();
    final now = DateTime.now();
    for (final entry in allEntries) {
      if (now.difference(entry.cachedAt) > expirationDuration) {
        try {
          File(entry.localPath).deleteSync();
          await _metadataStore.delete(entry.url);
        } catch (_) {}
      }
    }
  }
}

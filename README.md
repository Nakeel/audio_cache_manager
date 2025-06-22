# 🎧 audio_cache_manager

A hybrid audio caching manager for Flutter apps that supports:

- ✅ MP3 file caching
- ✅ HLS stream caching with proxy server
- ✅ AES encryption of audio files
- ✅ Hive-based metadata tracking
- ✅ Cache expiration and size control
- ✅ Playlist/album batch downloading

## 🔧 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  audio_cache_manager:
    git:
      url: https://github.com/your-username/audio_cache_manager.git
```

## 🚀 Usage

```dart
final mp3Handler = Mp3CacheHandler();
final file = await mp3Handler.download(mp3Url, encrypt: true);

final hlsHandler = HlsCacheHandler();
await hlsHandler.startServer();
final file = await hlsHandler.download(hlsUrl, encrypt: false);
final streamUrl = hlsHandler.getProxiedUrl(hlsUrl);
```

## 💡 Features

- AES encryption (custom key support coming)
- HLS local proxy streaming
- Hive metadata caching
- Works with `just_audio`

## 🛠 TODO

- Custom encryption key support
- Optional Isar metadata backend
- Playback history tracking

## 📄 License

MIT License
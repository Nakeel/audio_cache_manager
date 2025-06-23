class CacheEntry {
  final String url;
  final String localPath;
  final DateTime cachedAt;
  final String? playlistId;

  CacheEntry({
    required this.url,
    required this.localPath,
    required this.cachedAt,
    this.playlistId,
  });

  factory CacheEntry.fromMap(Map<String, dynamic> map) => CacheEntry(
    url: map['url'],
    localPath: map['localPath'],
    cachedAt: DateTime.parse(map['cachedAt']),
    playlistId: map['playlistId'],
  );

  Map<String, dynamic> toMap() => {
    'url': url,
    'localPath': localPath,
    'cachedAt': cachedAt.toIso8601String(),
    'playlistId': playlistId,
  };
}
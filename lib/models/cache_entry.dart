class CacheEntry {
  final String url;
  final String localPath;
  final DateTime cachedAt;

  CacheEntry({
    required this.url,
    required this.localPath,
    required this.cachedAt,
  });

  factory CacheEntry.fromMap(Map<String, dynamic> map) => CacheEntry(
        url: map['url'],
        localPath: map['localPath'],
        cachedAt: DateTime.parse(map['cachedAt']),
      );

  Map<String, dynamic> toMap() => {
        'url': url,
        'localPath': localPath,
        'cachedAt': cachedAt.toIso8601String(),
      };
}
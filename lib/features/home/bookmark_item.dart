class BookmarkItem {
  const BookmarkItem({
    required this.url,
    required this.title,
    required this.createdAtEpochMs,
  });

  final String url;
  final String title;
  final int createdAtEpochMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'title': title,
    'createdAtEpochMs': createdAtEpochMs,
  };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) {
    return BookmarkItem(
      url: json['url']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      createdAtEpochMs: (json['createdAtEpochMs'] as num?)?.toInt() ?? 0,
    );
  }
}

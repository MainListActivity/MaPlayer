class PlayHistoryItem {
  const PlayHistoryItem({
    required this.shareUrl,
    required this.pageUrl,
    required this.title,
    required this.coverUrl,
    required this.intro,
    required this.showDirName,
    required this.updatedAtEpochMs,
    this.lastEpisodeFileId,
    this.lastEpisodeName,
  });

  final String shareUrl;
  final String pageUrl;
  final String title;
  final String coverUrl;
  final String intro;
  final String showDirName;
  final String? lastEpisodeFileId;
  final String? lastEpisodeName;
  final int updatedAtEpochMs;

  PlayHistoryItem copyWith({
    String? shareUrl,
    String? pageUrl,
    String? title,
    String? coverUrl,
    String? intro,
    String? showDirName,
    String? lastEpisodeFileId,
    String? lastEpisodeName,
    int? updatedAtEpochMs,
  }) {
    return PlayHistoryItem(
      shareUrl: shareUrl ?? this.shareUrl,
      pageUrl: pageUrl ?? this.pageUrl,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      showDirName: showDirName ?? this.showDirName,
      lastEpisodeFileId: lastEpisodeFileId ?? this.lastEpisodeFileId,
      lastEpisodeName: lastEpisodeName ?? this.lastEpisodeName,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'shareUrl': shareUrl,
    'pageUrl': pageUrl,
    'title': title,
    'coverUrl': coverUrl,
    'intro': intro,
    'showDirName': showDirName,
    'lastEpisodeFileId': lastEpisodeFileId,
    'lastEpisodeName': lastEpisodeName,
    'updatedAtEpochMs': updatedAtEpochMs,
  };

  factory PlayHistoryItem.fromJson(Map<String, dynamic> json) {
    return PlayHistoryItem(
      shareUrl: json['shareUrl']?.toString() ?? '',
      pageUrl: json['pageUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString() ?? '',
      intro: json['intro']?.toString() ?? '',
      showDirName: json['showDirName']?.toString() ?? '',
      lastEpisodeFileId: json['lastEpisodeFileId']?.toString(),
      lastEpisodeName: json['lastEpisodeName']?.toString(),
      updatedAtEpochMs: (json['updatedAtEpochMs'] as num?)?.toInt() ?? 0,
    );
  }
}

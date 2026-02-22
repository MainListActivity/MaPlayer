class PlayHistoryItem {
  const PlayHistoryItem({
    required this.shareUrl,
    required this.pageUrl,
    required this.title,
    required this.coverUrl,
    this.coverHeaders = const <String, String>{},
    required this.intro,
    required this.showDirName,
    this.showFolderId,
    required this.updatedAtEpochMs,
    this.lastEpisodeFileId,
    this.lastEpisodeName,
    this.cachedEpisodes = const <PlayHistoryEpisode>[],
  });

  final String shareUrl;
  final String pageUrl;
  final String title;
  final String coverUrl;
  final Map<String, String> coverHeaders;
  final String intro;
  final String showDirName;
  final String? showFolderId;
  final String? lastEpisodeFileId;
  final String? lastEpisodeName;
  final List<PlayHistoryEpisode> cachedEpisodes;
  final int updatedAtEpochMs;

  PlayHistoryItem copyWith({
    String? shareUrl,
    String? pageUrl,
    String? title,
    String? coverUrl,
    Map<String, String>? coverHeaders,
    String? intro,
    String? showDirName,
    String? showFolderId,
    String? lastEpisodeFileId,
    String? lastEpisodeName,
    List<PlayHistoryEpisode>? cachedEpisodes,
    int? updatedAtEpochMs,
  }) {
    return PlayHistoryItem(
      shareUrl: shareUrl ?? this.shareUrl,
      pageUrl: pageUrl ?? this.pageUrl,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      coverHeaders: coverHeaders ?? this.coverHeaders,
      intro: intro ?? this.intro,
      showDirName: showDirName ?? this.showDirName,
      showFolderId: showFolderId ?? this.showFolderId,
      lastEpisodeFileId: lastEpisodeFileId ?? this.lastEpisodeFileId,
      lastEpisodeName: lastEpisodeName ?? this.lastEpisodeName,
      cachedEpisodes: cachedEpisodes ?? this.cachedEpisodes,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'shareUrl': shareUrl,
    'pageUrl': pageUrl,
    'title': title,
    'coverUrl': coverUrl,
    'coverHeaders': coverHeaders,
    'intro': intro,
    'showDirName': showDirName,
    'showFolderId': showFolderId,
    'lastEpisodeFileId': lastEpisodeFileId,
    'lastEpisodeName': lastEpisodeName,
    'cachedEpisodes': cachedEpisodes.map((e) => e.toJson()).toList(),
    'updatedAtEpochMs': updatedAtEpochMs,
  };

  factory PlayHistoryItem.fromJson(Map<String, dynamic> json) {
    return PlayHistoryItem(
      shareUrl: json['shareUrl']?.toString() ?? '',
      pageUrl: json['pageUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString() ?? json['cover']?.toString() ?? '',
      coverHeaders:
          (json['coverHeaders'] as Map?)
              ?.map(
                (key, value) =>
                    MapEntry(key.toString(), value?.toString() ?? ''),
              )
              .cast<String, String>() ??
          const <String, String>{},
      intro: json['intro']?.toString() ?? json['description']?.toString() ?? '',
      showDirName: json['showDirName']?.toString() ?? '',
      showFolderId: json['showFolderId']?.toString(),
      lastEpisodeFileId: json['lastEpisodeFileId']?.toString(),
      lastEpisodeName: json['lastEpisodeName']?.toString(),
      cachedEpisodes: (json['cachedEpisodes'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => PlayHistoryEpisode.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.fileId.isNotEmpty)
          .toList(),
      updatedAtEpochMs: (json['updatedAtEpochMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class PlayHistoryEpisode {
  const PlayHistoryEpisode({
    required this.fileId,
    required this.name,
    required this.shareFidToken,
  });

  final String fileId;
  final String name;
  final String shareFidToken;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fileId': fileId,
    'name': name,
    'shareFidToken': shareFidToken,
  };

  factory PlayHistoryEpisode.fromJson(Map<String, dynamic> json) {
    return PlayHistoryEpisode(
      fileId: json['fileId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      shareFidToken: json['shareFidToken']?.toString() ?? '',
    );
  }
}

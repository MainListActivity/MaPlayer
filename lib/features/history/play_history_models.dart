class PlayHistoryItem {
  const PlayHistoryItem({
    required this.shareUrl,
    required this.pageUrl,
    required this.title,
    required this.coverUrl,
    this.coverHeaders = const <String, String>{},
    this.year = '',
    this.rating = '',
    this.category = '',
    required this.intro,
    required this.showDirName,
    this.showFolderId,
    required this.updatedAtEpochMs,
    this.lastEpisodeFileId,
    this.lastEpisodeName,
    this.lastPositionMs,
    this.cachedEpisodes = const <PlayHistoryEpisode>[],
  });

  static const Object _sentinel = Object();

  final String shareUrl;
  final String pageUrl;
  final String title;
  final String coverUrl;
  final Map<String, String> coverHeaders;
  final String year;
  final String rating;
  final String category;
  final String intro;
  final String showDirName;
  final String? showFolderId;
  final String? lastEpisodeFileId;
  final String? lastEpisodeName;
  final int? lastPositionMs;
  final List<PlayHistoryEpisode> cachedEpisodes;
  final int updatedAtEpochMs;

  PlayHistoryItem copyWith({
    String? shareUrl,
    String? pageUrl,
    String? title,
    String? coverUrl,
    Map<String, String>? coverHeaders,
    String? year,
    String? rating,
    String? category,
    String? intro,
    String? showDirName,
    String? showFolderId,
    String? lastEpisodeFileId,
    String? lastEpisodeName,
    Object? lastPositionMs = _sentinel,
    List<PlayHistoryEpisode>? cachedEpisodes,
    int? updatedAtEpochMs,
  }) {
    return PlayHistoryItem(
      shareUrl: shareUrl ?? this.shareUrl,
      pageUrl: pageUrl ?? this.pageUrl,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      coverHeaders: coverHeaders ?? this.coverHeaders,
      year: year ?? this.year,
      rating: rating ?? this.rating,
      category: category ?? this.category,
      intro: intro ?? this.intro,
      showDirName: showDirName ?? this.showDirName,
      showFolderId: showFolderId ?? this.showFolderId,
      lastEpisodeFileId: lastEpisodeFileId ?? this.lastEpisodeFileId,
      lastEpisodeName: lastEpisodeName ?? this.lastEpisodeName,
      lastPositionMs: lastPositionMs == _sentinel
          ? this.lastPositionMs
          : lastPositionMs as int?,
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
    'year': year,
    'rating': rating,
    'category': category,
    'intro': intro,
    'showDirName': showDirName,
    'showFolderId': showFolderId,
    'lastEpisodeFileId': lastEpisodeFileId,
    'lastEpisodeName': lastEpisodeName,
    'lastPositionMs': lastPositionMs,
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
      year: json['year']?.toString() ?? json['vod_year']?.toString() ?? '',
      rating: json['rating']?.toString() ?? json['vod_score']?.toString() ?? '',
      category:
          json['category']?.toString() ?? json['type_name']?.toString() ?? '',
      intro: json['intro']?.toString() ?? json['description']?.toString() ?? '',
      showDirName: json['showDirName']?.toString() ?? '',
      showFolderId: json['showFolderId']?.toString(),
      lastEpisodeFileId: json['lastEpisodeFileId']?.toString(),
      lastEpisodeName: json['lastEpisodeName']?.toString(),
      lastPositionMs: (json['lastPositionMs'] as num?)?.toInt(),
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

class TvBoxConfig {
  const TvBoxConfig({
    required this.raw,
    required this.extras,
    required this.sites,
    required this.lives,
    required this.parses,
    required this.flags,
    required this.drives,
    required this.rules,
    this.spider,
    this.wallpaper,
    this.logo,
    this.ijk,
    this.ads,
    this.player,
    this.cache,
    this.proxy,
    this.dns,
    this.headers,
    this.ua,
    this.timeout,
    this.recommend,
    this.hotSearch,
    this.ext,
    this.resolvedExtRaw,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;

  final String? spider;
  final String? wallpaper;
  final String? logo;
  final List<TvBoxSite> sites;
  final List<TvBoxLive> lives;
  final List<TvBoxParse> parses;
  final List<String> flags;
  final Map<String, dynamic>? ijk;
  final List<dynamic>? ads;
  final List<TvBoxDrive> drives;
  final List<TvBoxRule> rules;
  final TvBoxPlayer? player;
  final Map<String, dynamic>? cache;
  final Map<String, dynamic>? proxy;
  final Map<String, dynamic>? dns;
  final Map<String, dynamic>? headers;
  final String? ua;
  final int? timeout;
  final dynamic recommend;
  final dynamic hotSearch;
  final dynamic ext;
  final Map<String, dynamic>? resolvedExtRaw;

  int get enabledSiteCount =>
      sites.where((site) => !site.searchableZero).length;
}

class TvBoxSite {
  const TvBoxSite({
    required this.raw,
    required this.extras,
    required this.key,
    required this.name,
    this.api,
    this.type,
    this.ext,
    this.resolvedExtRaw,
    this.searchable,
    this.quickSearch,
    this.filterable,
    this.changeable,
    this.playUrl,
    this.jar,
    this.categories,
    this.style,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final String key;
  final String name;
  final String? api;
  final int? type;
  final dynamic ext;
  final Map<String, dynamic>? resolvedExtRaw;
  final int? searchable;
  final int? quickSearch;
  final int? filterable;
  final int? changeable;
  final String? playUrl;
  final String? jar;
  final List<String>? categories;
  final dynamic style;

  bool get searchableZero => searchable == 0;
}

class TvBoxLive {
  const TvBoxLive({
    required this.raw,
    required this.extras,
    this.name,
    this.url,
    this.type,
    this.ua,
    this.epg,
    this.logo,
    this.header,
    this.ext,
    this.resolvedExtRaw,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final String? name;
  final String? url;
  final int? type;
  final String? ua;
  final String? epg;
  final String? logo;
  final Map<String, dynamic>? header;
  final dynamic ext;
  final Map<String, dynamic>? resolvedExtRaw;
}

class TvBoxParse {
  const TvBoxParse({
    required this.raw,
    required this.extras,
    this.name,
    this.url,
    this.type,
    this.ext,
    this.resolvedExtRaw,
    this.header,
    this.priority,
    this.web,
    this.flag,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final String? name;
  final String? url;
  final int? type;
  final dynamic ext;
  final Map<String, dynamic>? resolvedExtRaw;
  final Map<String, dynamic>? header;
  final int? priority;
  final bool? web;
  final String? flag;
}

class TvBoxDrive {
  const TvBoxDrive({
    required this.raw,
    required this.extras,
    this.provider,
    this.key,
    this.name,
    this.api,
    this.ext,
    this.resolvedExtRaw,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final String? provider;
  final String? key;
  final String? name;
  final String? api;
  final dynamic ext;
  final Map<String, dynamic>? resolvedExtRaw;
}

class TvBoxRule {
  const TvBoxRule({
    required this.raw,
    required this.extras,
    this.enable,
    this.match,
    this.replace,
    this.priority,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final bool? enable;
  final String? match;
  final String? replace;
  final int? priority;
}

class TvBoxPlayer {
  const TvBoxPlayer({
    required this.raw,
    required this.extras,
    this.ua,
    this.headers,
    this.timeout,
    this.retry,
  });

  final Map<String, dynamic> raw;
  final Map<String, dynamic> extras;
  final String? ua;
  final Map<String, dynamic>? headers;
  final int? timeout;
  final int? retry;
}

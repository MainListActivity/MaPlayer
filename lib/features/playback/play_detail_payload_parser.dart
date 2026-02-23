class PlayDetailPayload {
  const PlayDetailPayload({this.year, this.rating, this.category, this.intro});

  final String? year;
  final String? rating;
  final String? category;
  final String? intro;
}

PlayDetailPayload parsePlayDetailPayload(Map<String, dynamic> payload) {
  return PlayDetailPayload(
    year: _firstNonEmpty(payload, const <String>[
      'year',
      'vod_year',
      'releaseYear',
      'publishYear',
      '年份',
    ], _normalizeYear),
    rating: _firstNonEmpty(payload, const <String>[
      'rating',
      'score',
      'vod_score',
      'douban_score',
      'rate',
      '评分',
    ], _normalizeRating),
    category: _firstNonEmpty(payload, const <String>[
      'category',
      'type_name',
      'typeName',
      'genre',
      'genres',
      'class',
      '类别',
      '分类',
    ], _normalizeCategory),
    intro: _firstNonEmpty(payload, const <String>[
      'intro',
      'description',
      'desc',
      'vod_content',
      'content',
      '简介',
    ], _normalizeScalar),
  );
}

String? _firstNonEmpty(
  Map<String, dynamic> payload,
  List<String> keys,
  String? Function(Object? raw) normalizer,
) {
  for (final key in keys) {
    final value = normalizer(payload[key]);
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

String? _normalizeYear(Object? raw) {
  final value = _normalizeScalar(raw);
  if (value == null) return null;
  final matched = RegExp(r'(?:19|20)\d{2}').firstMatch(value);
  if (matched != null) {
    return matched.group(0);
  }
  return value;
}

String? _normalizeCategory(Object? raw) {
  if (raw is List) {
    final values = raw
        .map(_normalizeCategoryItem)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList();
    if (values.isEmpty) return null;
    return values.join(' / ');
  }
  return _normalizeCategoryItem(raw);
}

String? _normalizeCategoryItem(Object? raw) {
  if (raw is Map) {
    return _normalizeScalar(raw['name'] ?? raw['title'] ?? raw['value']);
  }
  return _normalizeScalar(raw);
}

String? _normalizeRating(Object? raw) {
  final value = _normalizeScalar(raw);
  if (value == null) return null;
  final matched = RegExp(r'(?:10(?:\.0)?|[0-9](?:\.[0-9])?)').firstMatch(value);
  if (matched != null) {
    return matched.group(0);
  }
  return value;
}

String? _normalizeScalar(Object? raw) {
  if (raw == null) return null;
  final value = raw.toString().trim();
  if (value.isEmpty) return null;
  return value;
}

({String coverUrl, Map<String, String> coverHeaders}) normalizeHistoryCover({
  required String coverUrl,
  Map<String, String>? coverHeaders,
}) {
  final normalizedUrl = _normalizeCoverUrl(coverUrl);
  if (normalizedUrl.isEmpty) {
    return (coverUrl: '', coverHeaders: const <String, String>{});
  }
  final normalizedHeaders = _normalizeCoverHeaders(
    coverUrl: normalizedUrl,
    coverHeaders: coverHeaders,
  );
  return (coverUrl: normalizedUrl, coverHeaders: normalizedHeaders);
}

String _normalizeCoverUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed;

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host == 'image.baidu.com' && path == '/search/down') {
    final direct = uri.queryParameters['url']?.trim() ?? '';
    if (direct.isNotEmpty) {
      final parsedDirect = Uri.tryParse(direct);
      if (parsedDirect != null &&
          (parsedDirect.scheme == 'http' || parsedDirect.scheme == 'https') &&
          parsedDirect.host.isNotEmpty) {
        return parsedDirect.toString();
      }
    }
  }
  return uri.toString();
}

Map<String, String> _normalizeCoverHeaders({
  required String coverUrl,
  Map<String, String>? coverHeaders,
}) {
  final base = <String, String>{};
  for (final entry in (coverHeaders ?? const <String, String>{}).entries) {
    final key = entry.key.trim();
    final value = entry.value.trim();
    if (key.isNotEmpty && value.isNotEmpty) {
      base[key] = value;
    }
  }

  final coverHost = Uri.tryParse(coverUrl)?.host.toLowerCase() ?? '';
  if (coverHost.endsWith('doubanio.com')) {
    return const <String, String>{'Referer': 'https://movie.douban.com/'};
  }

  if (base.isEmpty) return const <String, String>{};
  final refererHost =
      Uri.tryParse(base['Referer'] ?? '')?.host.toLowerCase() ?? '';
  if (coverHost.isNotEmpty &&
      refererHost.isNotEmpty &&
      coverHost != refererHost) {
    return const <String, String>{};
  }
  return base;
}

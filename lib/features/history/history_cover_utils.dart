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

  // If the URL points directly to doubanio.com, wrap it with the Baidu image
  // proxy to avoid 403/567 errors caused by Douban's hotlink protection.
  if (uri.host.toLowerCase().endsWith('doubanio.com')) {
    return Uri(
      scheme: 'https',
      host: 'image.baidu.com',
      path: '/search/down',
      queryParameters: {'url': uri.toString()},
    ).toString();
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

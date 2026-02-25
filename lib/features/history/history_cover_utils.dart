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
  // Remove whitespace/newlines that may be embedded in URLs extracted from HTML.
  final trimmed = raw.replaceAll(RegExp(r'\s+'), '').trim();
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

  final coverUri = Uri.tryParse(coverUrl);
  final coverHost = coverUri?.host.toLowerCase() ?? '';

  // For Baidu image proxy URLs, override headers with Baidu-appropriate values
  // so the proxy returns a valid image response.
  if (coverHost == 'image.baidu.com') {
    return <String, String>{
      'Referer': 'https://image.baidu.com/',
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    };
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

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ma_palyer/network/http_headers.dart';

abstract class TvBoxSourceResolver {
  Future<String> load(Uri uri, {required Duration timeout});
}

class DefaultTvBoxSourceResolver implements TvBoxSourceResolver {
  const DefaultTvBoxSourceResolver();

  @override
  Future<String> load(Uri uri, {required Duration timeout}) async {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      final response = await http
          .get(uri, headers: kDefaultHttpHeaders)
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return utf8.decode(response.bodyBytes);
    }

    if (uri.scheme == 'file' || uri.scheme.isEmpty) {
      final path = uri.scheme == 'file' ? uri.toFilePath() : uri.path;
      return File(path).readAsString();
    }

    throw UnsupportedError('Unsupported scheme: ${uri.scheme}');
  }
}

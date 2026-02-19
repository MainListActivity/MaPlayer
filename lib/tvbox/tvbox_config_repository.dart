import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ma_palyer/network/http_headers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TvBoxConfigRepository {
  static const String _sourceUrlKey = 'tvbox_source_url';
  static const String _rawJsonKey = 'tvbox_raw_json';

  Future<String> fetchFromUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw const FormatException('订阅地址格式不合法。');
    }

    final response = await http.get(uri, headers: kDefaultHttpHeaders);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('请求失败，状态码: ${response.statusCode}');
    }
    if (response.body.isEmpty) {
      throw const FormatException('返回内容为空。');
    }

    utf8.decode(response.bodyBytes);
    return response.body;
  }

  Future<void> saveDraft({
    required String sourceUrl,
    required String rawJson,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sourceUrlKey, sourceUrl);
    await prefs.setString(_rawJsonKey, rawJson);
  }

  Future<({String sourceUrl, String rawJson})> loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      sourceUrl: prefs.getString(_sourceUrlKey) ?? '',
      rawJson: prefs.getString(_rawJsonKey) ?? '',
    );
  }
}

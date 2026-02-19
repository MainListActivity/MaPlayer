import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ma_palyer/network/http_headers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TvBoxConfigRepository {
  static const String _sourceUrlKey = 'tvbox_source_url';
  static const String _rawJsonKey = 'tvbox_raw_json';

  String normalizeSubscriptionUrl(String rawUrl) {
    var input = rawUrl
        .trim()
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .replaceAll('：', ':')
        .replaceAll('／', '/');
    if (input.isEmpty) {
      throw const FormatException('订阅地址不能为空。');
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(input)) {
      input = 'http://$input';
    }

    final uri = Uri.tryParse(input);
    if (uri == null ||
        uri.host.isEmpty ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const FormatException('订阅地址格式不合法，请输入 http/https 地址。');
    }
    return uri.toString();
  }

  Future<String> fetchFromUrl(String url) async {
    final normalizedUrl = normalizeSubscriptionUrl(url);
    final uri = Uri.parse(normalizedUrl);

    try {
      final response = await http.get(uri, headers: kDefaultHttpHeaders);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('请求失败，状态码: ${response.statusCode}');
      }
      if (response.body.isEmpty) {
        throw const FormatException('返回内容为空。');
      }

      utf8.decode(response.bodyBytes);
      return response.body;
    } on SocketException catch (e) {
      throw FormatException('无法连接到 ${uri.host}（${e.message}）。请检查网络或 DNS 设置。');
    } on http.ClientException catch (e) {
      throw FormatException('请求失败: ${e.message}');
    }
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

  Future<bool> hasAnyDraftConfig() async {
    final draft = await loadDraft();
    return draft.sourceUrl.trim().isNotEmpty || draft.rawJson.trim().isNotEmpty;
  }
}

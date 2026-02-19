import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ma_palyer/network/http_headers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TvBoxConfigRepository {
  static const String _sourceUrlKey = 'tvbox_source_url';
  static const String _rawJsonKey = 'tvbox_raw_json';
  static const String _homeSiteUrlKey = 'home_site_url';
  static const String _defaultHomeSiteUrl = 'https://www.wogg.net/';
  static final ValueNotifier<int> configRevision = ValueNotifier<int>(0);

  String normalizeSubscriptionUrl(String rawUrl) {
    return normalizeHttpUrl(rawUrl, emptyMessage: '订阅地址不能为空。');
  }

  String normalizeHomeUrl(String rawUrl) {
    return normalizeHttpUrl(rawUrl, emptyMessage: '主页地址不能为空。');
  }

  String normalizeHttpUrl(String rawUrl, {required String emptyMessage}) {
    var input = rawUrl
        .trim()
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .replaceAll('：', ':')
        .replaceAll('／', '/');
    if (input.isEmpty) {
      throw FormatException(emptyMessage);
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

  Future<void> saveHomeSiteUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final next = normalizeHomeUrl(url);
    final prev = prefs.getString(_homeSiteUrlKey) ?? '';
    await prefs.setString(_homeSiteUrlKey, next);
    if (prev != next) {
      configRevision.value += 1;
    }
  }

  Future<String> loadHomeSiteUrlOrDefault() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_homeSiteUrlKey)?.trim() ?? '';
    if (stored.isEmpty) return _defaultHomeSiteUrl;
    try {
      return normalizeHomeUrl(stored);
    } on FormatException {
      return _defaultHomeSiteUrl;
    }
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
    final prevSourceUrl = prefs.getString(_sourceUrlKey) ?? '';
    final prevRawJson = prefs.getString(_rawJsonKey) ?? '';
    await prefs.setString(_sourceUrlKey, sourceUrl);
    await prefs.setString(_rawJsonKey, rawJson);
    if (prevSourceUrl != sourceUrl || prevRawJson != rawJson) {
      configRevision.value += 1;
    }
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

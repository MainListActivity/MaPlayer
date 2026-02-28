import 'dart:convert';
import 'package:ma_palyer/features/home/bookmark_item.dart';
import 'package:ma_palyer/features/home/home_page_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BookmarkRepository {
  static const String _key = 'bookmarks_v1';

  Future<List<BookmarkItem>> listAll() async {
    final items = await _loadAll();
    items.sort((a, b) => b.createdAtEpochMs.compareTo(a.createdAtEpochMs));
    return items;
  }

  Future<bool> contains(String url) async {
    final items = await _loadAll();
    return items.any((item) => item.url == url);
  }

  Future<void> add(String url, String title, {String? html}) async {
    final items = await _loadAll();
    // Don't add duplicates
    if (items.any((item) => item.url == url)) return;
    items.add(BookmarkItem(
      url: url,
      title: title,
      createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    ));
    await _saveAll(items);
    // Cache HTML snapshot if provided
    if (html != null && html.isNotEmpty) {
      await HomePageCache.instance.put(url, html);
    }
  }

  Future<void> remove(String url) async {
    final items = await _loadAll();
    items.removeWhere((item) => item.url == url);
    await _saveAll(items);
  }

  Future<List<BookmarkItem>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return <BookmarkItem>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <BookmarkItem>[];
    return decoded
        .whereType<Map>()
        .map((e) => BookmarkItem.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.url.isNotEmpty)
        .toList();
  }

  Future<void> _saveAll(List<BookmarkItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_key, json);
  }
}

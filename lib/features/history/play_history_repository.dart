import 'dart:convert';

import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlayHistoryRepository {
  static const String _historyKey = 'play_history_v1';

  Future<List<PlayHistoryItem>> listRecent({int limit = 50}) async {
    final items = await _loadAll();
    items.sort((a, b) => b.updatedAtEpochMs.compareTo(a.updatedAtEpochMs));
    if (items.length <= limit) return items;
    return items.sublist(0, limit);
  }

  Future<PlayHistoryItem?> findByShareUrl(String shareUrl) async {
    final normalized = shareUrl.trim();
    if (normalized.isEmpty) return null;
    final items = await _loadAll();
    for (final item in items) {
      if (item.shareUrl == normalized) {
        return item;
      }
    }
    return null;
  }

  Future<void> upsertByShareUrl(PlayHistoryItem item) async {
    final items = await _loadAll();
    var replaced = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].shareUrl == item.shareUrl) {
        items[i] = item;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      items.add(item);
    }
    await _saveAll(items);
  }

  Future<List<PlayHistoryItem>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null || raw.trim().isEmpty) {
      return <PlayHistoryItem>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <PlayHistoryItem>[];
    }
    return decoded
        .whereType<Map>()
        .map((e) => PlayHistoryItem.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.shareUrl.isNotEmpty)
        .toList();
  }

  Future<void> _saveAll(List<PlayHistoryItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_historyKey, json);
  }
}

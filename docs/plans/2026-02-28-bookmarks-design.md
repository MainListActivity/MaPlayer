# Bookmarks Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a bookmarks/favorites feature to the home page with HTML caching and a HeaderBar for quick access.

**Architecture:** New `BookmarkItem` model + `BookmarkRepository` (SharedPreferences JSON, same pattern as `PlayHistoryRepository`). HTML cached via existing `HomePageCache`. New `HomeHeaderBar` widget sits above the WebView in `HomePage`.

**Tech Stack:** Flutter, shared_preferences, flutter_inappwebview, HomePageCache (existing)

---

### Task 1: BookmarkItem Data Model

**Files:**
- Create: `lib/features/home/bookmark_item.dart`

**Step 1: Create the model class**

```dart
class BookmarkItem {
  const BookmarkItem({
    required this.url,
    required this.title,
    required this.createdAtEpochMs,
  });

  final String url;
  final String title;
  final int createdAtEpochMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'title': title,
    'createdAtEpochMs': createdAtEpochMs,
  };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) {
    return BookmarkItem(
      url: json['url']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      createdAtEpochMs: (json['createdAtEpochMs'] as num?)?.toInt() ?? 0,
    );
  }
}
```

**Step 2: Verify no compile errors**

Run: `cd /Users/y/IdeaProjects/MaPlayer/ma_palyer && flutter analyze lib/features/home/bookmark_item.dart`

**Step 3: Commit**

```bash
git add lib/features/home/bookmark_item.dart
git commit -m "feat: add BookmarkItem data model"
```

---

### Task 2: BookmarkRepository

**Files:**
- Create: `lib/features/home/bookmark_repository.dart`

**Step 1: Create the repository**

Follows exact same pattern as `lib/features/history/play_history_repository.dart`:
- SharedPreferences with key `bookmarks_v1`
- JSON array serialization
- Methods: `listAll()`, `add(url, title)`, `remove(url)`, `contains(url)`

```dart
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
```

**Step 2: Verify no compile errors**

Run: `flutter analyze lib/features/home/bookmark_repository.dart`

**Step 3: Commit**

```bash
git add lib/features/home/bookmark_repository.dart
git commit -m "feat: add BookmarkRepository with SharedPreferences persistence"
```

---

### Task 3: HomeHeaderBar Widget

**Files:**
- Create: `lib/features/home/home_header_bar.dart`

**Step 1: Create the HeaderBar widget**

A stateless widget that receives callbacks from the parent. Matches the app's dark theme (#101622 bg, #F47B25 accent).

```dart
import 'package:flutter/material.dart';
import 'package:ma_palyer/features/home/bookmark_item.dart';

class HomeHeaderBar extends StatelessWidget {
  const HomeHeaderBar({
    super.key,
    required this.currentTitle,
    required this.isBookmarked,
    required this.bookmarks,
    required this.onToggleBookmark,
    required this.onSelectBookmark,
  });

  final String currentTitle;
  final bool isBookmarked;
  final List<BookmarkItem> bookmarks;
  final VoidCallback onToggleBookmark;
  final ValueChanged<BookmarkItem> onSelectBookmark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0xFF192233),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // Left: bookmarks dropdown
          PopupMenuButton<BookmarkItem>(
            tooltip: '收藏夹',
            offset: const Offset(0, 40),
            icon: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bookmarks_outlined, size: 18, color: Colors.white70),
                SizedBox(width: 4),
                Icon(Icons.arrow_drop_down, size: 18, color: Colors.white70),
              ],
            ),
            onSelected: onSelectBookmark,
            itemBuilder: (context) {
              if (bookmarks.isEmpty) {
                return [
                  const PopupMenuItem<BookmarkItem>(
                    enabled: false,
                    child: Text('暂无收藏', style: TextStyle(color: Colors.white38)),
                  ),
                ];
              }
              return bookmarks.map((item) => PopupMenuItem<BookmarkItem>(
                value: item,
                child: Text(
                  item.title.isNotEmpty ? item.title : item.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )).toList();
            },
          ),
          // Center: current page title
          Expanded(
            child: Text(
              currentTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          // Right: bookmark toggle
          IconButton(
            icon: Icon(
              isBookmarked ? Icons.star : Icons.star_border,
              color: isBookmarked ? const Color(0xFFF47B25) : Colors.white70,
              size: 20,
            ),
            tooltip: isBookmarked ? '取消收藏' : '收藏此页',
            onPressed: onToggleBookmark,
          ),
        ],
      ),
    );
  }
}
```

**Step 2: Verify no compile errors**

Run: `flutter analyze lib/features/home/home_header_bar.dart`

**Step 3: Commit**

```bash
git add lib/features/home/home_header_bar.dart
git commit -m "feat: add HomeHeaderBar widget for bookmarks UI"
```

---

### Task 4: Integrate HeaderBar into HomePage

**Files:**
- Modify: `lib/features/home/home_page.dart`

**Step 1: Add state fields and imports**

Add to imports:
```dart
import 'package:ma_palyer/features/home/bookmark_repository.dart';
import 'package:ma_palyer/features/home/bookmark_item.dart';
import 'package:ma_palyer/features/home/home_header_bar.dart';
```

Add to `_HomePageState` fields:
```dart
final _bookmarkRepository = BookmarkRepository();
List<BookmarkItem> _bookmarks = [];
bool _isCurrentBookmarked = false;
String _currentTitle = '';
```

**Step 2: Add bookmark methods**

```dart
Future<void> _refreshBookmarks() async {
  final bookmarks = await _bookmarkRepository.listAll();
  final isBookmarked = await _bookmarkRepository.contains(_currentUrl);
  if (!mounted) return;
  setState(() {
    _bookmarks = bookmarks;
    _isCurrentBookmarked = isBookmarked;
  });
}

Future<void> _toggleBookmark() async {
  if (_isCurrentBookmarked) {
    await _bookmarkRepository.remove(_currentUrl);
  } else {
    String title = _currentTitle;
    String? html;
    final controller = _webController;
    if (controller != null) {
      try {
        final t = await controller.evaluateJavascript(source: 'document.title');
        if (t is String && t.isNotEmpty) title = t;
        final h = await controller.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        if (h is String && h.isNotEmpty) html = h;
      } catch (_) {}
    }
    await _bookmarkRepository.add(_currentUrl, title, html: html);
  }
  await _refreshBookmarks();
}

Future<void> _onSelectBookmark(BookmarkItem item) async {
  final controller = _webController;
  if (controller == null) return;
  // Try to load cached HTML first
  final cached = await HomePageCache.instance.get(item.url);
  setState(() {
    _currentUrl = item.url;
    _currentTitle = item.title;
  });
  if (cached != null) {
    _loadedFromCache = true;
    await controller.loadData(data: cached, baseUrl: WebUri(item.url));
  } else {
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(item.url)));
  }
  await _refreshBookmarks();
}
```

**Step 3: Call _refreshBookmarks in initState and onLoadStop**

In `initState`, after `_loadHomeUrl()`:
```dart
_refreshBookmarks();
```

In the `onLoadStop` callback, update title and bookmark state:
```dart
// After _injectPlayButtons calls, before cache logic:
try {
  final title = await controller.evaluateJavascript(source: 'document.title');
  if (title is String && title.isNotEmpty && mounted) {
    setState(() => _currentTitle = title);
  }
} catch (_) {}
// Update current URL from WebView
final loadedUrl = (await controller.getUrl())?.toString();
if (loadedUrl != null && loadedUrl.isNotEmpty) {
  _currentUrl = loadedUrl;
}
await _refreshBookmarks();
```

**Step 4: Add HeaderBar to build method**

Replace the `Column` body. Insert `HomeHeaderBar` before the `Expanded` WebView:

```dart
children: [
  HomeHeaderBar(
    currentTitle: _currentTitle,
    isBookmarked: _isCurrentBookmarked,
    bookmarks: _bookmarks,
    onToggleBookmark: _toggleBookmark,
    onSelectBookmark: _onSelectBookmark,
  ),
  const SizedBox(height: 8),
  Expanded(
    // ... existing WebView code
  ),
],
```

**Step 5: Verify no compile errors**

Run: `flutter analyze lib/features/home/`

**Step 6: Commit**

```bash
git add lib/features/home/home_page.dart
git commit -m "feat: integrate bookmarks HeaderBar into home page"
```

---

### Task 5: Manual Testing & Polish

**Step 1: Run the app**

Run: `flutter run`

**Step 2: Verify:**
- HeaderBar appears above WebView
- Page title updates as you navigate
- Star button toggles bookmark state
- Dropdown shows bookmarked pages
- Clicking a bookmark loads the page (from cache if available)
- Bookmarks persist after app restart

**Step 3: Final commit if any fixes needed**

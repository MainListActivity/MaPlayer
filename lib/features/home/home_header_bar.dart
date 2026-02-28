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

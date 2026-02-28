import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Disk cache for home page HTML snapshots.
///
/// HTML is stored under `<cacheDir>/home_page_cache/<md5_of_url>.html`.
class HomePageCache {
  HomePageCache._();
  static final HomePageCache instance = HomePageCache._();

  Directory? _diskDir;

  Future<Directory> _ensureDiskDir() async {
    if (_diskDir != null) return _diskDir!;
    final cacheRoot = await getTemporaryDirectory();
    final dir = Directory('${cacheRoot.path}/home_page_cache');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _diskDir = dir;
    return dir;
  }

  String _keyFor(String url) => md5.convert(utf8.encode(url)).toString();

  /// Returns cached HTML for [url], or `null` if not cached.
  Future<String?> get(String url) async {
    try {
      final dir = await _ensureDiskDir();
      final file = File('${dir.path}/${_keyFor(url)}.html');
      if (file.existsSync()) {
        final html = await file.readAsString();
        if (html.isNotEmpty) return html;
      }
    } catch (e) {
      debugPrint('[HomePageCache] disk read error: $e');
    }
    return null;
  }

  /// Writes [html] to disk cache for [url].
  Future<void> put(String url, String html) async {
    try {
      final dir = await _ensureDiskDir();
      await File('${dir.path}/${_keyFor(url)}.html')
          .writeAsString(html, flush: true);
    } catch (e) {
      debugPrint('[HomePageCache] disk write error: $e');
    }
  }

  /// Removes all cached HTML files.
  Future<void> clear() async {
    try {
      final dir = await _ensureDiskDir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        _diskDir = null;
      }
    } catch (e) {
      debugPrint('[HomePageCache] clear error: $e');
    }
  }
}

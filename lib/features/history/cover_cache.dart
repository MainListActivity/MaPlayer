import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A simple disk + memory cache for cover images.
///
/// Images are stored under `<cacheDir>/cover_cache/<md5>.jpg`.
/// An in-memory LRU map avoids redundant disk reads within the same session.
class CoverCache {
  CoverCache._();
  static final CoverCache instance = CoverCache._();

  static const int _maxMemoryEntries = 60;

  final Map<String, Uint8List> _memory = <String, Uint8List>{};
  Directory? _diskDir;

  Future<Directory> _ensureDiskDir() async {
    if (_diskDir != null) return _diskDir!;
    final cacheRoot = await getTemporaryDirectory();
    final dir = Directory('${cacheRoot.path}/cover_cache');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _diskDir = dir;
    return dir;
  }

  String _keyFor(String url) =>
      md5.convert(utf8.encode(url)).toString();

  /// Returns cached bytes for [url], or `null` if not cached.
  Future<Uint8List?> get(String url) async {
    final key = _keyFor(url);

    // 1. Memory hit
    final mem = _memory[key];
    if (mem != null) return mem;

    // 2. Disk hit
    try {
      final dir = await _ensureDiskDir();
      final file = File('${dir.path}/$key.jpg');
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _putMemory(key, bytes);
          return bytes;
        }
      }
    } catch (e) {
      debugPrint('[CoverCache] disk read error: $e');
    }

    return null;
  }

  /// Downloads [url] with optional [headers], caches to disk+memory, and
  /// returns the bytes. Returns `null` on failure.
  Future<Uint8List?> fetch(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      final bytes = response.bodyBytes;
      final key = _keyFor(url);
      _putMemory(key, bytes);

      // Write to disk in background.
      _writeDisk(key, bytes);

      return bytes;
    } catch (e) {
      debugPrint('[CoverCache] fetch error: $e');
      return null;
    }
  }

  void _putMemory(String key, Uint8List bytes) {
    // Simple eviction: remove oldest entries when over limit.
    if (_memory.length >= _maxMemoryEntries) {
      final keysToRemove =
          _memory.keys.take(_memory.length - _maxMemoryEntries + 1).toList();
      for (final k in keysToRemove) {
        _memory.remove(k);
      }
    }
    _memory[key] = bytes;
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    try {
      final dir = await _ensureDiskDir();
      await File('${dir.path}/$key.jpg').writeAsBytes(bytes, flush: true);
    } catch (e) {
      debugPrint('[CoverCache] disk write error: $e');
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class QuarkPlaybackWebViewResult {
  const QuarkPlaybackWebViewResult({this.cookieHeader, this.m3u8Url});

  final String? cookieHeader;
  final String? m3u8Url;

  bool get isEmpty {
    final cookie = cookieHeader?.trim() ?? '';
    final url = m3u8Url?.trim() ?? '';
    return cookie.isEmpty && url.isEmpty;
  }
}

abstract class QuarkPlaybackCookieProvider {
  Future<QuarkPlaybackWebViewResult?> resolveForVideo(String fileId);
}

class QuarkHeadlessWebViewCookieProvider
    implements QuarkPlaybackCookieProvider {
  QuarkHeadlessWebViewCookieProvider();

  static const _desktopChromeUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/145.0.0.0 Safari/537.36';
  static const _panBaseUrl = 'https://pan.quark.cn/';
  static const _drivePcBaseUrl = 'https://drive-pc.quark.cn/';

  void _logCookie(String message) {
    debugPrint('[QuarkCookie] $message');
  }

  @override
  Future<QuarkPlaybackWebViewResult?> resolveForVideo(String fileId) async {
    if (fileId.trim().isEmpty) return null;
    if (InAppWebViewPlatform.instance == null) {
      _logCookie('webview unavailable, skip cookie refresh');
      return null;
    }
    final targetUrl = 'https://pan.quark.cn/list#/video/${fileId.trim()}';
    final loaded = Completer<void>();
    HeadlessInAppWebView? webView;
    try {
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(targetUrl),
          headers: <String, String>{
            'Referer': _panBaseUrl,
            'Origin': 'https://pan.quark.cn',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
                'image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
          },
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          thirdPartyCookiesEnabled: true,
          userAgent: _desktopChromeUa,
        ),
        onLoadStop: (_, __) {
          if (!loaded.isCompleted) {
            loaded.complete();
          }
        },
        onReceivedError: (_, request, error) {
          _logCookie(
            'headless load error: url=${request.url} type=${error.type} desc=${error.description}',
          );
          if (!loaded.isCompleted) {
            loaded.complete();
          }
        },
        onReceivedHttpError: (_, request, errorResponse) {
          _logCookie(
            'headless http error: url=${request.url} status=${errorResponse.statusCode}',
          );
          if (request.isForMainFrame == true && !loaded.isCompleted) {
            loaded.complete();
          }
        },
      );
      await webView.run();
      await Future.any<void>(<Future<void>>[
        loaded.future,
        Future<void>.delayed(const Duration(seconds: 12)),
      ]);
      final controller = await webView.webViewController;
      if (controller != null) {
        await _waitUntilDocumentReady(controller);
      }
      final cookieHeader = await _collectCookieHeader();
      final m3u8Url = controller == null
          ? null
          : await _extractM3u8Url(controller);
      if (cookieHeader.isEmpty && (m3u8Url == null || m3u8Url.isEmpty)) {
        _logCookie('headless cookie+m3u8 empty after loading $targetUrl');
        return null;
      }
      _logCookie(
        'headless resolved: cookieLength=${cookieHeader.length}, m3u8=${m3u8Url ?? ''}',
      );
      return QuarkPlaybackWebViewResult(
        cookieHeader: cookieHeader.isEmpty ? null : cookieHeader,
        m3u8Url: m3u8Url,
      );
    } catch (e) {
      _logCookie('headless cookie refresh failed: $e');
      return null;
    } finally {
      await webView?.dispose();
    }
  }

  Future<String> _collectCookieHeader() async {
    final cookieManager = CookieManager.instance();
    final cookieMap = <String, String>{};
    final allCookies = await cookieManager.getAllCookies();
    for (final cookie in allCookies) {
      final domain = cookie.domain?.toLowerCase() ?? '';
      if (!domain.contains('quark.cn')) continue;
      cookieMap[cookie.name] = cookie.value;
    }
    final panCookies = await cookieManager.getCookies(url: WebUri(_panBaseUrl));
    for (final cookie in panCookies) {
      cookieMap[cookie.name] = cookie.value;
    }
    final drivePcCookies = await cookieManager.getCookies(
      url: WebUri(_drivePcBaseUrl),
    );
    for (final cookie in drivePcCookies) {
      cookieMap[cookie.name] = cookie.value;
    }
    return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _waitUntilDocumentReady(
    InAppWebViewController controller,
  ) async {
    for (var i = 0; i < 20; i++) {
      final value = await controller.evaluateJavascript(
        source: 'document.readyState',
      );
      final state = value?.toString().toLowerCase() ?? '';
      if (state == 'complete') {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<String?> _extractM3u8Url(InAppWebViewController controller) async {
    try {
      final raw = await controller.evaluateJavascript(
        source: '''
(() => {
  const candidates = [];
  const add = (raw) => {
    if (!raw || typeof raw !== 'string') return;
    const trimmed = raw.trim();
    if (!trimmed) return;
    const idx = trimmed.toLowerCase().indexOf('.m3u8');
    if (idx < 0) return;
    const end = Math.max(
      trimmed.indexOf('"', idx),
      trimmed.indexOf("'", idx),
      trimmed.indexOf(' ', idx)
    );
    const value = (end > idx ? trimmed.slice(0, end) : trimmed)
      .replace(/\\\\u002F/g, '/')
      .replace(/\\\\\\//g, '/');
    candidates.push(value);
  };

  try {
    const videoNodes = document.querySelectorAll('video, source');
    for (const node of videoNodes) {
      add(node.currentSrc || node.src || node.getAttribute('src') || '');
    }
  } catch (_) {}

  try {
    const entries = performance.getEntriesByType('resource') || [];
    for (const e of entries) {
      add(e.name || '');
    }
  } catch (_) {}

  try {
    const html = document.documentElement?.innerHTML || '';
    const matched = html.match(/https?:\\\\/\\\\/[^"'\\\\s<>]+\\\\.m3u8[^"'\\\\s<>]*/ig) || [];
    for (const v of matched) add(v);
  } catch (_) {}

  const unique = [];
  const seen = new Set();
  for (const item of candidates) {
    if (!seen.has(item)) {
      seen.add(item);
      unique.push(item);
    }
  }
  return JSON.stringify({ m3u8: unique.length > 0 ? unique[0] : '' });
})();
''',
      );
      final decoded = jsonDecode(raw?.toString() ?? '{}');
      if (decoded is! Map) return null;
      final url = decoded['m3u8']?.toString().trim() ?? '';
      return url.isEmpty ? null : url;
    } catch (e) {
      _logCookie('extract m3u8 failed: $e');
      return null;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';

class QuarkLoginWebviewPage extends StatefulWidget {
  const QuarkLoginWebviewPage({super.key, required this.authService});

  final QuarkAuthService authService;

  static Future<bool> open(
    BuildContext context,
    QuarkAuthService authService,
  ) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => QuarkLoginWebviewPage(authService: authService),
      ),
    );
    return result ?? false;
  }

  @override
  State<QuarkLoginWebviewPage> createState() => _QuarkLoginWebviewPageState();
}

class _QuarkLoginWebviewPageState extends State<QuarkLoginWebviewPage> {
  final CookieManager _cookieManager = CookieManager.instance();

  static const _quarkMain = 'https://www.quark.cn/';
  static const _quarkPan = 'https://pan.quark.cn/list#/list/all';
  static const _desktopUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  InAppWebViewController? _controller;
  bool _submitting = false;
  String _statusText = '请先在夸克首页登录，再进入网盘页';
  String _currentUrl = _quarkMain;

  Future<void> _trySyncCookies() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _statusText = '正在检测登录状态...';
    });
    try {
      final cookieMap = <String, String>{};
      final mainCookies = await _cookieManager.getCookies(url: WebUri(_quarkMain));
      final panCookies = await _cookieManager.getCookies(
        url: WebUri('https://pan.quark.cn/'),
      );
      for (final cookie in <Cookie>[...mainCookies, ...panCookies]) {
        cookieMap[cookie.name] = cookie.value;
      }

      final header = cookieMap.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      if (header.isEmpty) {
        if (!mounted) return;
        setState(() {
          _statusText = '尚未读取到 Cookie，请先完成登录';
        });
        return;
      }

      final auth = await widget.authService.syncAuthStateFromCookies(header);
      if (!mounted) return;
      if (auth == null) {
        setState(() {
          _statusText = '检测到 Cookie，但登录态仍无效，请继续登录后重试';
        });
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('登录态同步成功')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = '登录态同步失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('夸克登录'),
        actions: [
          IconButton(
            tooltip: '检测登录态',
            onPressed: _trySyncCookies,
            icon: const Icon(Icons.check_circle_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF192233),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_statusText),
                const SizedBox(height: 4),
                Text(
                  '当前页面: $_currentUrl',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    _controller?.loadUrl(
                      urlRequest: URLRequest(url: WebUri(_quarkMain)),
                    );
                  },
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('打开夸克首页'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    _controller?.loadUrl(
                      urlRequest: URLRequest(url: WebUri(_quarkPan)),
                    );
                  },
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('前往网盘页'),
                ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_quarkMain)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                userAgent: _desktopUa,
                thirdPartyCookiesEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
              },
              onUpdateVisitedHistory: (controller, url, isReload) {
                if (!mounted) return;
                setState(() {
                  _currentUrl = url?.toString() ?? _currentUrl;
                });
              },
              onReceivedError: (controller, request, error) {
                if (!mounted) return;
                setState(() {
                  _statusText =
                      '页面加载失败(${error.type}): ${error.description}';
                });
              },
              onLoadStop: (controller, url) {
                _trySyncCookies();
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _controller?.reload(),
        icon: const Icon(Icons.refresh),
        label: const Text('刷新页面'),
      ),
    );
  }
}

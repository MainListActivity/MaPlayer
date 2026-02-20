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

  static const _quarkPan = 'https://pan.quark.cn/';
  static const _quarkDrivePc = 'https://drive-pc.quark.cn/';
  static const _desktopChromeUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/145.0.0.0 Safari/537.36';

  InAppWebViewController? _controller;
  bool _submitting = false;
  int _progress = 0;
  String _statusText = '请先在夸克首页登录，再进入网盘页';
  String _currentUrl = _quarkPan;

  void _logWebView(String message) {
    debugPrint('[QuarkWebView] $message');
  }

  URLRequest _buildRequest(
    String url, {
    String? referer,
  }) {
    return URLRequest(
      url: WebUri(url),
      headers: <String, String>{
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
            'image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
        'Upgrade-Insecure-Requests': '1',
        'Referer': referer ?? _quarkPan,
      },
    );
  }

  Future<void> _trySyncCookies() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _statusText = '正在检测登录状态...';
    });
    try {
      final cookieMap = <String, String>{};
      final allCookies = await _cookieManager.getAllCookies();
      final allQuarkCookies = allCookies.where((cookie) {
        final domain = cookie.domain?.toLowerCase();
        if (domain == null || domain.isEmpty) return false;
        return domain.contains('quark.cn');
      }).toList();
      final panCookies = await _cookieManager.getCookies(url: WebUri(_quarkPan));
      final drivePcCookies = await _cookieManager.getCookies(
        url: WebUri(_quarkDrivePc),
      );
      for (final cookie in <Cookie>[
        ...allQuarkCookies,
        ...panCookies,
        ...drivePcCookies,
      ]) {
        cookieMap[cookie.name] = cookie.value;
      }
      _logWebView(
        'cookies collected: count=${cookieMap.length}, '
        'keys=${cookieMap.keys.toList()}',
      );

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
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _progress >= 100 ? 1 : _progress / 100,
                  minHeight: 2,
                  backgroundColor: Colors.white12,
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
                      urlRequest: _buildRequest(_quarkPan),
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
              initialUrlRequest: _buildRequest(_quarkPan),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                thirdPartyCookiesEnabled: true,
                isInspectable: true,
                userAgent: _desktopChromeUa,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                _logWebView('created');
              },
              onLoadStart: (controller, url) {
                _logWebView('load start: ${url?.toString() ?? 'null'}');
                if (!mounted) return;
                setState(() {
                  _progress = 0;
                  _statusText = '页面加载中...';
                  _currentUrl = url?.toString() ?? _currentUrl;
                });
              },
              onProgressChanged: (controller, progress) {
                if (!mounted) return;
                setState(() {
                  _progress = progress;
                });
              },
              onUpdateVisitedHistory: (controller, url, isReload) {
                _logWebView(
                  'visited: ${url?.toString() ?? 'null'}, reload=$isReload',
                );
                if (!mounted) return;
                setState(() {
                  _currentUrl = url?.toString() ?? _currentUrl;
                });
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final request = navigationAction.request;
                _logWebView(
                  'request: method=${request.method ?? 'GET'} '
                  'mainFrame=${navigationAction.isForMainFrame} '
                  'url=${request.url?.toString() ?? 'null'}',
                );
                return NavigationActionPolicy.ALLOW;
              },
              onReceivedError: (controller, request, error) {
                _logWebView(
                  'error: mainFrame=${request.isForMainFrame} '
                  'url=${request.url.toString()} '
                  'type=${error.type} '
                  'desc=${error.description}',
                );
                if (!mounted) return;
                setState(() {
                  _statusText =
                      '页面加载失败(${error.type}): ${error.description}，请检查网络或重试';
                });
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                _logWebView(
                  'http error: mainFrame=${request.isForMainFrame} '
                  'url=${request.url.toString()} '
                  'status=${errorResponse.statusCode} '
                  'reason=${errorResponse.reasonPhrase ?? 'unknown'}',
                );
                if (!mounted) return;
                setState(() {
                  _statusText =
                      '页面返回异常 HTTP ${errorResponse.statusCode} (${errorResponse.reasonPhrase ?? 'unknown'})';
                });
              },
              onConsoleMessage: (controller, consoleMessage) {
                _logWebView(
                  'console(${consoleMessage.messageLevel.toString()}): '
                  '${consoleMessage.message}',
                );
              },
              onLoadStop: (controller, url) {
                _logWebView('load stop: ${url?.toString() ?? 'null'}');
                if (!mounted) return;
                setState(() {
                  _progress = 100;
                  _statusText = '页面加载完成，可继续登录';
                });
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

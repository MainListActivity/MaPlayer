import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ma_palyer/app/app_route.dart';

import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/player/player_page.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _configRepository = TvBoxConfigRepository();

  InAppWebViewController? _webController;
  String _currentUrl = 'https://www.wogg.net/';
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    TvBoxConfigRepository.configRevision.addListener(_onConfigRevisionChanged);
    _loadHomeUrl();
  }

  @override
  void dispose() {
    TvBoxConfigRepository.configRevision.removeListener(
      _onConfigRevisionChanged,
    );
    super.dispose();
  }

  Future<void> _onConfigRevisionChanged() async {
    await _loadHomeUrl(forceReload: true);
  }

  Future<void> _loadHomeUrl({bool forceReload = false}) async {
    final url = await _configRepository.loadHomeSiteUrlOrDefault();
    if (!mounted) return;
    setState(() {
      _currentUrl = url;
    });
    if (forceReload && _webController != null) {
      await _webController!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  Future<void> _handlePlayRequest(Map<String, dynamic> payload) async {
    if (_isBusy) return;
    final shareUrl = payload['shareUrl']?.toString() ?? '';
    final pageUrl = payload['pageUrl']?.toString() ?? _currentUrl;
    final title = payload['title']?.toString() ?? '';
    final cover = payload['cover']?.toString();
    final intro = payload['intro']?.toString();
    if (shareUrl.isEmpty) {
      _showSnack('未找到夸克分享链接');
      return;
    }

    await Navigator.pushNamed(
      context,
      AppRoutes.player,
      arguments: PlayerPageArgs(
        shareRequest: SharePlayRequest(
          shareUrl: shareUrl,
          pageUrl: pageUrl,
          title: title.isEmpty ? '未命名剧集' : title,
          coverUrl: cover,
          intro: intro,
        ),
        title: title.isEmpty ? '未命名剧集' : title,
      ),
    );
  }

  Future<void> _injectPlayButtons() async {
    final controller = _webController;
    if (controller == null) return;
    await controller.evaluateJavascript(
      source: '''
(function() {
  const PLAY_CLASS = 'ma-player-injected-btn';
  const links = document.querySelectorAll('a[href^="https://pan.quark.cn/s/"], a[href^="http://pan.quark.cn/s/"]');
  links.forEach((a) => {
    const next = a.nextElementSibling;
    if (next && next.classList && next.classList.contains(PLAY_CLASS)) {
      return;
    }
    const btn = document.createElement('button');
    btn.textContent = '播放';
    btn.className = PLAY_CLASS;
    btn.style.marginLeft = '8px';
    btn.style.padding = '2px 8px';
    btn.style.fontSize = '12px';
    btn.style.background = '#f47b25';
    btn.style.border = 'none';
    btn.style.color = '#fff';
    btn.style.borderRadius = '8px';
    btn.style.cursor = 'pointer';
    btn.onclick = function(evt) {
      evt.preventDefault();
      evt.stopPropagation();
      const card = a.closest('article, .post, .item, .entry, li, .module-item') || document.body;
      const titleNode = card.querySelector('h1, h2, h3, .title, .module-item-title, .entry-title') || a;
      const introNode = card.querySelector('p, .desc, .module-item-note, .content, .entry-content');
      const imgNode = card.querySelector('img');
      const payload = {
        shareUrl: a.href,
        pageUrl: location.href,
        title: (titleNode && titleNode.textContent ? titleNode.textContent : document.title || '').trim(),
        intro: (introNode && introNode.textContent ? introNode.textContent : '').trim(),
        cover: imgNode ? (imgNode.src || '') : ''
      };
      window.flutter_inappwebview.callHandler('maPlayerPlay', payload);
      return false;
    };
    a.insertAdjacentElement('afterend', btn);
  });
})();
''',
    );
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text.length > 50 ? '${text.substring(0, 50)}...' : text),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '详情',
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('错误详情'),
                content: SingleChildScrollView(child: Text(text)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: InAppWebViewPlatform.instance == null
                ? Container(
                    key: const Key('home-webview-placeholder'),
                    decoration: BoxDecoration(
                      color: const Color(0xFF192233),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'WebView unavailable in current environment',
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(_currentUrl)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                      ),
                      onWebViewCreated: (controller) {
                        _webController = controller;
                        controller.addJavaScriptHandler(
                          handlerName: 'maPlayerPlay',
                          callback: (args) async {
                            if (args.isEmpty || args.first is! Map) {
                              return;
                            }
                            final payload = Map<String, dynamic>.from(
                              args.first as Map,
                            );
                            await _handlePlayRequest(payload);
                          },
                        );
                      },
                      onLoadStop: (controller, url) async {
                        await _injectPlayButtons();
                        await Future<void>.delayed(
                          const Duration(milliseconds: 300),
                        );
                        await _injectPlayButtons();
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

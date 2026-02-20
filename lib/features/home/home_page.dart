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
  final bool _isBusy = false;

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
    final coverHeaders = (payload['coverHeaders'] as Map?)
        ?.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        )
        .cast<String, String>();
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
          coverHeaders: coverHeaders,
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
  const AUTO_FLAG_KEY = 'ma_player_auto_detail_open_ts';
  const AUTO_MAX_AGE_MS = 2 * 60 * 1000;
  const AUTO_PLAYED_KEY = '__maPlayerAutoPlayedForUrl';

  function toAbsolute(url) {
    try {
      return new URL(url, location.href).toString();
    } catch (_) {
      return '';
    }
  }

  function extractCoverUrl(imgNode) {
    if (!imgNode) return '';
    const srcSet = imgNode.currentSrc || imgNode.getAttribute('data-src') || imgNode.getAttribute('data-original') || imgNode.getAttribute('data-lazy-src') || imgNode.getAttribute('src') || '';
    if (!srcSet) return '';
    const first = srcSet.split(',')[0].trim().split(' ')[0].trim();
    return toAbsolute(first);
  }

  function extractPayload(a) {
    const card = a.closest('article, .post, .item, .entry, li, .module-item, .module-info, .myui-content__detail, .stui-content__detail') || document.body;
    const titleNode = card.querySelector('h1, h2, h3, .title, .module-item-title, .entry-title, .page-title, .video-info-header h1, .myui-content__detail .title') || a;
    const introNode = card.querySelector('.video-info-content, .module-info-introduction-content, .desc, .module-item-note, .entry-content, .myui-content__detail .data, .stui-content__detail p, p');
    const imgNode = card.querySelector('img[data-src], img[data-original], img[src], .module-item-pic img, .myui-content__thumb img, .stui-content__thumb img');
    const cover = extractCoverUrl(imgNode);
    const payload = {
      shareUrl: toAbsolute(a.getAttribute('href') || a.href || ''),
      pageUrl: location.href,
      title: (titleNode && titleNode.textContent ? titleNode.textContent : document.title || '').trim(),
      intro: (introNode && introNode.textContent ? introNode.textContent : '').trim(),
      cover: cover,
      coverHeaders: cover ? { Referer: location.href, Origin: location.origin } : {}
    };
    return payload;
  }

  function shouldMarkAutoForClick(anchor) {
    if (!anchor) return false;
    const href = anchor.getAttribute('href') || '';
    if (!href || href.startsWith('javascript:') || href.startsWith('#')) return false;
    if (/pan\\.quark\\.cn\\/s\\//i.test(href)) return false;
    let target;
    try {
      target = new URL(href, location.href);
    } catch (_) {
      return false;
    }
    if (target.origin !== location.origin) return false;
    const path = target.pathname.toLowerCase();
    if (path === location.pathname && target.search === location.search) return false;
    if (/(voddetail|detail|movie|tv|film|video|vod|show)/.test(path)) return true;
    return !!anchor.closest('.module-item, .myui-vodlist__box, .stui-vodlist__box, .video-item, .post');
  }

  if (!window.__maPlayerDetailClickHooked) {
    document.addEventListener('click', function(evt) {
      const anchor = evt.target && evt.target.closest ? evt.target.closest('a[href]') : null;
      if (!anchor) return;
      if (shouldMarkAutoForClick(anchor)) {
        sessionStorage.setItem(AUTO_FLAG_KEY, String(Date.now()));
      }
    }, true);
    window.__maPlayerDetailClickHooked = true;
  }

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
      const payload = extractPayload(a);
      window.flutter_inappwebview.callHandler('maPlayerPlay', payload);
      return false;
    };
    a.insertAdjacentElement('afterend', btn);
  });

  const autoTs = Number(sessionStorage.getItem(AUTO_FLAG_KEY) || '0');
  const shouldAutoPlay = Number.isFinite(autoTs) && autoTs > 0 && (Date.now() - autoTs) <= AUTO_MAX_AGE_MS;
  if (!shouldAutoPlay) {
    return;
  }
  const alreadyForUrl = window[AUTO_PLAYED_KEY];
  if (alreadyForUrl === location.href) {
    return;
  }
  const firstLink = links.length > 0 ? links[0] : null;
  if (!firstLink) {
    return;
  }
  window[AUTO_PLAYED_KEY] = location.href;
  sessionStorage.removeItem(AUTO_FLAG_KEY);
  setTimeout(function() {
    window.flutter_inappwebview.callHandler('maPlayerPlay', extractPayload(firstLink));
  }, 60);
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

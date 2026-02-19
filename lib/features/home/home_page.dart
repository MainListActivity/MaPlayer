import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_login_webview_page.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:ma_palyer/features/playback/episode_picker_sheet.dart';
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
  final _historyRepository = PlayHistoryRepository();
  final _authService = QuarkAuthService();
  late final SharePlayOrchestrator _orchestrator;

  InAppWebViewController? _webController;
  String _currentUrl = 'https://www.wogg.net/';
  String _statusText = '加载中...';
  bool _isBusy = false;
  List<PlayHistoryItem> _recentItems = const <PlayHistoryItem>[];

  @override
  void initState() {
    super.initState();
    _orchestrator = SharePlayOrchestrator(authService: _authService);
    TvBoxConfigRepository.configRevision.addListener(_onConfigRevisionChanged);
    _loadHomeUrl();
    _loadRecent();
  }

  @override
  void dispose() {
    TvBoxConfigRepository.configRevision.removeListener(_onConfigRevisionChanged);
    super.dispose();
  }

  Future<void> _onConfigRevisionChanged() async {
    await _loadHomeUrl(forceReload: true);
    await _loadRecent();
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

  Future<void> _loadRecent() async {
    final recent = await _historyRepository.listRecent(limit: 10);
    if (!mounted) return;
    setState(() {
      _recentItems = recent;
    });
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

    setState(() {
      _isBusy = true;
      _statusText = '准备剧集列表...';
    });

    try {
      final prepared = await _prepareWithLogin(
        SharePlayRequest(
          shareUrl: shareUrl,
          pageUrl: pageUrl,
          title: title.isEmpty ? '未命名剧集' : title,
          coverUrl: cover,
          intro: intro,
        ),
      );
      if (!mounted) return;
      final selected = await EpisodePickerSheet.show(
        context,
        title: prepared.request.title,
        episodes: prepared.episodes,
        preferredFileId: prepared.preferredFileId,
      );
      if (selected == null) {
        setState(() {
          _statusText = '已取消';
        });
        return;
      }
      setState(() {
        _statusText = '正在解析播放地址...';
      });
      final media = await _orchestrator.playEpisode(prepared, selected);
      if (!mounted) return;
      await Navigator.pushNamed(
        context,
        AppRoutes.player,
        arguments: PlayerPageArgs(
          media: media,
          title: prepared.request.title,
        ),
      );
      await _loadRecent();
      if (!mounted) return;
      setState(() {
        _statusText = '播放完成';
      });
    } catch (e) {
      _showSnack('处理失败: $e');
      if (!mounted) return;
      setState(() {
        _statusText = '处理失败';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<PreparedEpisodeSelection> _prepareWithLogin(SharePlayRequest request) async {
    try {
      return await _orchestrator.prepareEpisodes(request);
    } on QuarkException catch (e) {
      final requiresAuth = e.code == 'AUTH_REQUIRED';
      if (!requiresAuth) {
        rethrow;
      }
      final ok = await QuarkLoginWebviewPage.open(context, _authService);
      if (!ok) {
        throw Exception('未完成夸克登录');
      }
      return _orchestrator.prepareEpisodes(request);
    }
  }

  Future<void> _openRecent(PlayHistoryItem item) async {
    await _handlePlayRequest(<String, dynamic>{
      'shareUrl': item.shareUrl,
      'pageUrl': item.pageUrl,
      'title': item.title,
      'cover': item.coverUrl,
      'intro': item.intro,
    });
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Container(
            key: const Key('home-page-title'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF192233),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2E3B56)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Home', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('站点: $_currentUrl', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                Text('状态: $_statusText', style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_recentItems.isNotEmpty)
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final item = _recentItems[index];
                  return InkWell(
                    onTap: () => _openRecent(item),
                    child: Container(
                      width: 280,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C2940),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text(
                            item.lastEpisodeName ?? '点击选集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemCount: _recentItems.length,
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: InAppWebViewPlatform.instance == null
                ? Container(
                    key: const Key('home-webview-placeholder'),
                    decoration: BoxDecoration(
                      color: const Color(0xFF192233),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text('WebView unavailable in current environment'),
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
                        await Future<void>.delayed(const Duration(milliseconds: 300));
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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/home/home_webview_bridge_contract.dart';

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
  String? _remoteBridgeJsUrl;
  String? _bridgeScriptAsset;
  DateTime? _lastBridgeErrorAt;
  String? _lastBridgeErrorMessage;
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
    final data = await Future.wait<Object?>(<Future<Object?>>[
      _configRepository.loadHomeSiteUrlOrDefault(),
      _configRepository.loadHomeBridgeRemoteJsUrlOrNull(),
    ]);
    final url = data[0]! as String;
    final remoteJsUrl = data[1] as String?;
    if (!mounted) return;
    setState(() {
      _currentUrl = url;
      _remoteBridgeJsUrl = remoteJsUrl;
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
        ?.map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''))
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
    final bridgeScript = await _loadBridgeScriptAsset();
    await controller.evaluateJavascript(source: bridgeScript);
    final initConfig = HomeWebViewBridgeContract.buildInitConfig(
      remoteJsUrl: _remoteBridgeJsUrl,
    );
    await controller.evaluateJavascript(
      source:
          '''
(function() {
  try {
    const config = ${jsonEncode(initConfig)};
    if (window.MaPlayerBridge && typeof window.MaPlayerBridge.init === 'function') {
      window.MaPlayerBridge.init(config);
    }
  } catch (_) {}
})();
''',
    );
  }

  Future<String> _loadBridgeScriptAsset() async {
    final cached = _bridgeScriptAsset;
    if (cached != null) return cached;
    final loaded = await rootBundle.loadString(
      'assets/js/home_webview_bridge.js',
    );
    _bridgeScriptAsset = loaded;
    return loaded;
  }

  void _handleBridgeError(String message) {
    final now = DateTime.now();
    final lastAt = _lastBridgeErrorAt;
    final lastMessage = _lastBridgeErrorMessage;
    if (lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 2) &&
        lastMessage == message) {
      return;
    }
    _lastBridgeErrorAt = now;
    _lastBridgeErrorMessage = message;
    _showSnack('远程脚本已回退本地解析: $message');
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
                          handlerName:
                              HomeWebViewBridgeContract.playHandlerName,
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
                        controller.addJavaScriptHandler(
                          handlerName:
                              HomeWebViewBridgeContract.errorHandlerName,
                          callback: (args) async {
                            final first = args.isNotEmpty ? args.first : null;
                            String message = '未知错误';
                            if (first is Map) {
                              final raw = first['message']?.toString() ?? '';
                              if (raw.trim().isNotEmpty) {
                                message = raw.trim();
                              }
                            } else if (first != null) {
                              final raw = first.toString().trim();
                              if (raw.isNotEmpty) {
                                message = raw;
                              }
                            }
                            _handleBridgeError(message);
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

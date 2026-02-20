import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_login_webview_page.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:ma_palyer/features/playback/episode_picker_sheet.dart';
import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/player/player_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _historyRepository = PlayHistoryRepository();
  final _authService = QuarkAuthService();
  late final SharePlayOrchestrator _orchestrator;

  List<PlayHistoryItem> _items = const <PlayHistoryItem>[];
  bool _isLoading = true;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _orchestrator = SharePlayOrchestrator(authService: _authService);
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final items = await _historyRepository.listRecent(limit: 100);
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  Future<void> _handlePlayRequest(Map<String, dynamic> payload) async {
    if (_isBusy) return;
    final shareUrl = payload['shareUrl']?.toString() ?? '';
    final pageUrl = payload['pageUrl']?.toString() ?? '';
    final title = payload['title']?.toString() ?? '';
    final cover = payload['cover']?.toString();
    final intro = payload['intro']?.toString();
    if (shareUrl.isEmpty) {
      _showSnack('未找到夸克分享链接');
      return;
    }

    setState(() => _isBusy = true);

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
      if (selected == null) return;

      final media = await _orchestrator.playEpisode(prepared, selected);
      if (!mounted) return;
      await Navigator.pushNamed(
        context,
        AppRoutes.player,
        arguments: PlayerPageArgs(media: media, title: prepared.request.title),
      );
      await _loadHistory();
    } catch (e) {
      _showSnack('处理失败: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<PreparedEpisodeSelection> _prepareWithLogin(
    SharePlayRequest request,
  ) async {
    try {
      return await _orchestrator.prepareEpisodes(request);
    } on QuarkException catch (e) {
      final requiresAuth = e.code == 'AUTH_REQUIRED';
      if (!requiresAuth) rethrow;
      final ok = await QuarkLoginWebviewPage.open(context, _authService);
      if (!ok) throw Exception('未完成夸克登录');
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
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Play History',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const Center(
                    child: Text(
                      '暂无播放记录',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 260,
                          childAspectRatio: 16 / 12,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return InkWell(
                        onTap: _isBusy ? null : () => _openRecent(item),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C2940),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Container(
                                  color: const Color(0xFF101622),
                                  child: item.coverUrl.isNotEmpty
                                      ? Image.network(
                                          item.coverUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Center(
                                                child: Icon(
                                                  Icons.movie,
                                                  size: 48,
                                                  color: Colors.white24,
                                                ),
                                              ),
                                        )
                                      : const Center(
                                          child: Icon(
                                            Icons.movie,
                                            size: 48,
                                            color: Colors.white24,
                                          ),
                                        ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      item.lastEpisodeName ?? '点击选集',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

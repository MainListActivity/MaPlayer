import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/history/history_cover_utils.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:ma_palyer/features/playback/play_detail_payload_parser.dart';
import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/player/player_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> with RouteAware {
  final _historyRepository = PlayHistoryRepository();

  List<PlayHistoryItem> _items = const <PlayHistoryItem>[];
  bool _isLoading = true;
  final bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      AppRouteObserver.instance.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    AppRouteObserver.instance.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
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
    final coverHeaders = (payload['coverHeaders'] as Map?)
        ?.map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''))
        .cast<String, String>();
    final detail = parsePlayDetailPayload(payload);
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
          year: detail.year,
          rating: detail.rating,
          category: detail.category,
          intro: detail.intro,
        ),
        title: title.isEmpty ? '未命名剧集' : title,
      ),
    );
    await _loadHistory();
  }

  Future<void> _openRecent(PlayHistoryItem item) async {
    final normalizedCover = normalizeHistoryCover(
      coverUrl: item.coverUrl,
      coverHeaders: item.coverHeaders,
    );
    await _handlePlayRequest(<String, dynamic>{
      'shareUrl': item.shareUrl,
      'pageUrl': item.pageUrl,
      'title': item.title,
      'cover': normalizedCover.coverUrl,
      'coverHeaders': normalizedCover.coverHeaders,
      'year': item.year,
      'rating': item.rating,
      'category': item.category,
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
            '播放历史',
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
                          maxCrossAxisExtent: 240,
                          childAspectRatio: 0.52,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final normalizedCover = normalizeHistoryCover(
                        coverUrl: item.coverUrl,
                        coverHeaders: item.coverHeaders,
                      );
                      final pos = item.lastPositionMs;
                      final episodeSubtitle = (pos != null && pos > 0)
                          ? '${item.lastEpisodeName ?? '点击选集'} · ${_formatPosition(pos)}'
                          : (item.lastEpisodeName ?? '点击选集');
                      return InkWell(
                        onTap: _isBusy ? null : () => _openRecent(item),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C2940),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF2A3B5E)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AspectRatio(
                                aspectRatio: 270 / 405,
                                child: Container(
                                  color: const Color(0xFF101622),
                                  child: normalizedCover.coverUrl.isNotEmpty
                                      ? _CoverImage(
                                          url: normalizedCover.coverUrl,
                                          headers: normalizedCover.coverHeaders,
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
                              SizedBox(
                                height: 84,
                                child: Container(
                                  color: const Color(0xFF162236),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
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
                                        const SizedBox(height: 6),
                                        Text(
                                          episodeSubtitle,
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

/// Displays a cover image. For Baidu image proxy URLs (which return
/// `Content-Disposition: attachment`), fetches bytes manually and uses
/// [Image.memory] since [Image.network] treats attachment responses as empty.
class _CoverImage extends StatefulWidget {
  const _CoverImage({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _needsManualFetch = false;

  static const _fallback = Center(
    child: Icon(Icons.movie, size: 48, color: Colors.white24),
  );

  @override
  void initState() {
    super.initState();
    final uri = Uri.tryParse(widget.url);
    _needsManualFetch =
        uri != null && uri.host.toLowerCase() == 'image.baidu.com';
    if (_needsManualFetch) {
      _fetchBytes();
    }
  }

  Future<void> _fetchBytes() async {
    try {
      final response = await http.get(
        Uri.parse(widget.url),
        headers: widget.headers.isNotEmpty ? widget.headers : null,
      );
      if (!mounted) return;
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        setState(() => _bytes = response.bodyBytes);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_needsManualFetch) {
      if (_failed) return _fallback;
      if (_bytes == null) {
        return const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }

    return Image.network(
      widget.url,
      headers: widget.headers.isEmpty ? null : widget.headers,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _fallback,
    );
  }
}

String _formatPosition(int ms) {
  final total = Duration(milliseconds: ms);
  final h = total.inHours;
  final m = total.inMinutes.remainder(60);
  final s = total.inSeconds.remainder(60);
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

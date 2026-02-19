import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/core/spider/spider_runtime.dart';
import 'package:ma_palyer/core/spider/spider_source_registry.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.registry, this.runtime});

  final SpiderSourceRegistry? registry;
  final SpiderRuntime? runtime;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final SpiderSourceRegistry _registry;
  late final SpiderRuntime _runtime;
  final _searchController = TextEditingController();

  bool _isLoadingSources = true;
  bool _isLoadingVideos = false;
  String? _sourceErrorText;
  String? _videoErrorText;
  List<TvBoxSite> _sources = const <TvBoxSite>[];
  List<_HomeVideo> _videos = const <_HomeVideo>[];
  String? _selectedSourceKey;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? SpiderSourceRegistry();
    _runtime =
        widget.runtime ??
        SpiderRuntime(registry: _registry, logger: (m) => debugPrint(m));
    _searchController.addListener(_onSearchChanged);
    TvBoxConfigRepository.configRevision.addListener(_onConfigChanged);
    _loadSources(forceRefresh: true);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    TvBoxConfigRepository.configRevision.removeListener(_onConfigChanged);
    _runtime.dispose();
    super.dispose();
  }

  void _onConfigChanged() {
    _loadSources(forceRefresh: true);
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadSources({required bool forceRefresh}) async {
    setState(() {
      _isLoadingSources = true;
      _sourceErrorText = null;
      _videoErrorText = null;
    });
    try {
      final config = await _registry.loadConfig(forceRefresh: forceRefresh);
      if (!mounted) return;
      final sources = config.sites
          .where((s) => s.key.trim().isNotEmpty)
          .toList();
      final selected = _resolveSelectedSource(sources, _selectedSourceKey);
      setState(() {
        _sources = sources;
        _selectedSourceKey = selected;
        _isLoadingSources = false;
      });
      if (selected != null) {
        await _loadVideosForSource(selected, forceRefresh: true);
      } else {
        setState(() {
          _videos = const <_HomeVideo>[];
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourceErrorText = '$e';
        _isLoadingSources = false;
        _sources = const <TvBoxSite>[];
        _videos = const <_HomeVideo>[];
      });
    }
  }

  String? _resolveSelectedSource(List<TvBoxSite> sources, String? preferred) {
    if (sources.isEmpty) return null;
    if (preferred != null) {
      for (final source in sources) {
        if (source.key == preferred) return preferred;
      }
    }
    return sources.first.key;
  }

  Future<void> _loadVideosForSource(
    String sourceKey, {
    required bool forceRefresh,
  }) async {
    setState(() {
      _isLoadingVideos = true;
      _videoErrorText = null;
      _selectedSourceKey = sourceKey;
      if (forceRefresh) {
        _videos = const <_HomeVideo>[];
      }
    });

    try {
      final spider = await _runtime.getSpider(sourceKey);
      final home = await spider.homeContent(filter: true);
      var videos = _parseVideos(sourceKey, home);

      if (videos.isEmpty) {
        final firstCategory = _firstCategoryId(home);
        if (firstCategory != null && firstCategory.isNotEmpty) {
          final category = await spider.categoryContent(firstCategory, page: 1);
          videos = _parseVideos(sourceKey, category);
        }
      }

      if (!mounted) return;
      setState(() {
        _videos = videos;
        _isLoadingVideos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingVideos = false;
        _videoErrorText = '$e';
        _videos = const <_HomeVideo>[];
      });
    }
  }

  List<_HomeVideo> _parseVideos(
    String sourceKey,
    Map<String, dynamic> payload,
  ) {
    final rawList = payload['list'];
    if (rawList is! List) return const <_HomeVideo>[];
    return rawList
        .whereType<Map>()
        .map(
          (raw) =>
              _HomeVideo.fromMap(sourceKey, Map<String, dynamic>.from(raw)),
        )
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  String? _firstCategoryId(Map<String, dynamic> payload) {
    final classes = payload['class'];
    if (classes is! List) return null;
    for (final item in classes) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['type_id']?.toString().trim() ?? '';
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  List<_HomeVideo> get _filteredVideos {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _videos;
    return _videos.where((v) => v.title.toLowerCase().contains(query)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _loadSources(forceRefresh: true),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final videos = _filteredVideos;
          final isCompact = constraints.maxWidth < 980;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Header(sourceCount: _sources.length, videoCount: _videos.length),
              const SizedBox(height: 12),
              TextField(
                key: const Key('home-search-input'),
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '搜索影片',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Navigator.pushNamed(context, AppRoutes.player),
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('进入 Playback Debug'),
              ),
              const SizedBox(height: 16),
              if (_isLoadingSources)
                const Center(child: CircularProgressIndicator())
              else if (_sourceErrorText != null)
                _MessageCard(
                  title: '首页加载失败',
                  text: _sourceErrorText!,
                  icon: Icons.error_outline,
                )
              else if (_sources.isEmpty)
                const _MessageCard(
                  title: '暂无线路',
                  text: '请先在设置页完成 TVBox 配置并解析。',
                  icon: Icons.route_outlined,
                )
              else if (isCompact)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SourceMenu(
                      sources: _sources,
                      selectedSourceKey: _selectedSourceKey,
                      onTap: (sourceKey) =>
                          _loadVideosForSource(sourceKey, forceRefresh: true),
                    ),
                    const SizedBox(height: 12),
                    _VideoPanel(
                      isLoading: _isLoadingVideos,
                      errorText: _videoErrorText,
                      videos: videos,
                    ),
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 260,
                      child: _SourceMenu(
                        sources: _sources,
                        selectedSourceKey: _selectedSourceKey,
                        onTap: (sourceKey) =>
                            _loadVideosForSource(sourceKey, forceRefresh: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _VideoPanel(
                        isLoading: _isLoadingVideos,
                        errorText: _videoErrorText,
                        videos: videos,
                      ),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.sourceCount, required this.videoCount});

  final int sourceCount;
  final int videoCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      key: const Key('home-page-title'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF263750), Color(0xFF192233)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Home',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '线路 $sourceCount 条，影片 $videoCount 条',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _SourceMenu extends StatelessWidget {
  const _SourceMenu({
    required this.sources,
    required this.selectedSourceKey,
    required this.onTap,
  });

  final List<TvBoxSite> sources;
  final String? selectedSourceKey;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF192233),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '线路',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final source in sources)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SourceMenuItem(
                site: source,
                selected: source.key == selectedSourceKey,
                onTap: () => onTap(source.key),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceMenuItem extends StatelessWidget {
  const _SourceMenuItem({
    required this.site,
    required this.selected,
    required this.onTap,
  });

  final TvBoxSite site;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('source-menu-${site.key}'),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0x332A8BFF) : const Color(0xFF232F48),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF2A8BFF) : const Color(0xFF2E3B56),
          ),
        ),
        child: Text(
          site.name.isEmpty ? site.key : site.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? const Color(0xFFDDEBFF) : Colors.white70,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _VideoPanel extends StatelessWidget {
  const _VideoPanel({
    required this.isLoading,
    required this.errorText,
    required this.videos,
  });

  final bool isLoading;
  final String? errorText;
  final List<_HomeVideo> videos;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (errorText != null) {
      return _MessageCard(
        title: '影片加载失败',
        text: errorText!,
        icon: Icons.error_outline,
      );
    }
    if (videos.isEmpty) {
      return const _MessageCard(
        title: '该线路暂无影片',
        text: '可以切换线路或下拉刷新重试。',
        icon: Icons.movie_outlined,
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF192233),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: videos.map((video) => _VideoCard(video: video)).toList(),
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video});

  final _HomeVideo video;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('video-card-${video.id}'),
      width: 178,
      decoration: BoxDecoration(
        color: const Color(0xFF232F48),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: video.coverUrl.isEmpty
                  ? const ColoredBox(
                      color: Color(0xFF2A3A5A),
                      child: Center(
                        child: Icon(
                          Icons.movie_creation_outlined,
                          color: Colors.white38,
                        ),
                      ),
                    )
                  : Image.network(
                      video.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Color(0xFF2A3A5A),
                        child: Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  video.remark.isEmpty ? '暂无信息' : video.remark,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.title,
    required this.text,
    required this.icon,
  });

  final String title;
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF192233),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFF47B25)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(text, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeVideo {
  const _HomeVideo({
    required this.id,
    required this.title,
    required this.coverUrl,
    required this.remark,
  });

  final String id;
  final String title;
  final String coverUrl;
  final String remark;

  factory _HomeVideo.fromMap(String sourceKey, Map<String, dynamic> map) {
    final id = _pickString(map, const ['vod_id', 'id']);
    final title = _pickString(map, const ['vod_name', 'name', 'title']);
    final coverUrl = _pickString(map, const ['vod_pic', 'pic', 'cover']);
    final remark = _pickString(map, const ['vod_remarks', 'remarks', 'note']);
    return _HomeVideo(
      id: id.isEmpty ? '$sourceKey:$title' : id,
      title: title,
      coverUrl: coverUrl,
      remark: remark,
    );
  }

  static String _pickString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }
}

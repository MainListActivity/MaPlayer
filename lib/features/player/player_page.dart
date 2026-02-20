import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/media_kit_player_controller.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/playback/media_file_parser.dart';

class PlayerPageArgs {
  const PlayerPageArgs({this.media, this.shareRequest, this.title});

  final PlayableMedia? media;
  final SharePlayRequest? shareRequest;
  final String? title;
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, this.args});

  final PlayerPageArgs? args;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final MediaKitPlayerController _playerController;
  late final VideoController _videoController;
  late final SharePlayOrchestrator _orchestrator;

  bool _isLoading = false;
  String? _errorMessage;

  List<ParsedMediaInfo> _allEpisodes = [];
  Map<String, List<ParsedMediaInfo>> _groupedEpisodes = {};
  List<String> _groupKeys = []; // Ordered group keys (e.g. "Season-Episode")

  String? _currentGroupKey;
  ParsedMediaInfo? _currentPlayingEpisode;
  PlayableMedia? _currentMedia;

  @override
  void initState() {
    super.initState();
    _playerController = MediaKitPlayerController();
    _videoController = VideoController(_playerController.player);
    _orchestrator = SharePlayOrchestrator();

    final args = widget.args;
    if (args != null) {
      if (args.shareRequest != null) {
        _prepareAndPlayFromShare(args.shareRequest!);
      } else if (args.media != null) {
        _openMedia(args.media!);
      }
    }
  }

  @override
  void dispose() {
    _playerController.dispose();
    super.dispose();
  }

  Future<void> _prepareAndPlayFromShare(SharePlayRequest request) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prepared = await _orchestrator.prepareEpisodes(request);
      if (!mounted) return;

      final parsed = prepared.shareEpisodeMap.values
          .map(MediaFileParser.parse)
          .toList();

      // Sort episodes: Season first, then Episode
      parsed.sort((a, b) {
        if (a.season != b.season) {
          return (a.season ?? 0).compareTo(b.season ?? 0);
        }
        if (a.episode != b.episode) {
          return (a.episode ?? 0).compareTo(b.episode ?? 0);
        }
        return a.name.compareTo(b.name);
      });

      final grouped = <String, List<ParsedMediaInfo>>{};
      final keys = <String>{};
      for (final ep in parsed) {
        final key = ep.groupKey;
        keys.add(key);
        grouped.putIfAbsent(key, () => []).add(ep);
      }

      setState(() {
        _allEpisodes = parsed;
        _groupedEpisodes = grouped;
        _groupKeys = keys.toList();
      });

      // Find the episode to play default
      ParsedMediaInfo? toPlay;
      if (prepared.preferredFileId != null) {
        toPlay = parsed
            .where((e) => e.file.fid == prepared.preferredFileId)
            .firstOrNull;
      }
      toPlay ??= parsed.firstOrNull;

      if (toPlay != null) {
        await _playParsedEpisode(prepared, toPlay);
      } else {
        setState(() {
          _errorMessage = '未找到可播放的文件';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '加载失败: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _playParsedEpisode(
    PreparedEpisodeSelection prepared,
    ParsedMediaInfo episode,
  ) async {
    setState(() {
      _isLoading = true;
      _currentPlayingEpisode = episode;
      _currentGroupKey = episode.groupKey;
    });

    try {
      final candidate = prepared.episodes.firstWhere(
        (e) => e.fileId == episode.file.fid,
      );
      final media = await _orchestrator.playEpisode(prepared, candidate);
      if (!mounted) return;

      setState(() {
        _currentMedia = media;
      });
      await _openMedia(media);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '播放失败: $e';
        _isLoading = false;
      });
    }
  }

  void _showResolutionPicker() {
    if (_currentGroupKey == null || _groupedEpisodes[_currentGroupKey] == null)
      return;

    final episodesInGroup = _groupedEpisodes[_currentGroupKey]!;
    if (episodesInGroup.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  '选择清晰度',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const Divider(color: Color(0xFF2E3B56), height: 1),
              ...episodesInGroup.map((ep) {
                final isCurrent =
                    ep.file.fid == _currentPlayingEpisode?.file.fid;
                return ListTile(
                  title: Text(
                    ep.displayResolution,
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFFF47B25) : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: Color(0xFFF47B25))
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    if (!isCurrent) {
                      _playParsedEpisode(
                        PreparedEpisodeSelection(
                          request: widget.args!.shareRequest!,
                          showDirName: '',
                          episodes: _allEpisodes
                              .map(
                                (e) => EpisodeCandidate(
                                  fileId: e.id,
                                  name: e.name,
                                  selectedByDefault: false,
                                ),
                              )
                              .toList(),
                          preferredFileId: null,
                          shareEpisodeMap: {
                            for (var e in _allEpisodes) e.id: e.file,
                          },
                        ),
                        ep,
                      );
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openMedia(PlayableMedia media) async {
    setState(() {
      _isLoading = true;
    });
    try {
      await _playerController.open(media.url, headers: media.headers);
    } catch (e) {
      if (!mounted) return;
      // You can handle error here, for now it's silent or can log
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildTopNavigation() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF101622),
        border: Border(bottom: BorderSide(color: Color(0xFF232F48))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  Navigator.pushReplacementNamed(context, AppRoutes.home);
                },
              ),
              const SizedBox(width: 8),
              SvgPicture.asset(
                'logo/ma_player_logo.svg',
                width: 32,
                height: 32,
              ),
              const SizedBox(width: 12),
              const Text(
                'Ma Player',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          // We can put a fake search or user avatar here just to match design layout
          Row(
            children: [
              Container(
                width: 200,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2332),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2E3B56)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.search, color: Color(0xFF92A4C9), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: 'Search...',
                          hintStyle: TextStyle(
                            color: Color(0xFF92A4C9),
                            fontSize: 13,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              const CircleAvatar(
                radius: 16,
                backgroundColor: Color(0xFF2E3B56),
                child: Icon(Icons.person, size: 18, color: Colors.white70),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayerArea() {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 16,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Video(controller: _videoController),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2332),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF232F48)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _showResolutionPicker,
                    icon: const Icon(
                      Icons.dns,
                      size: 18,
                      color: Color(0xFFF47B25),
                    ),
                    label: Text(
                      _currentPlayingEpisode?.displayResolution ?? 'Server 1',
                      style: const TextStyle(color: Colors.white),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF2E3B56)),
                      backgroundColor: const Color(0xFF101622),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.subtitles_outlined,
                      color: Colors.white70,
                    ),
                    label: const Text(
                      'English',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.favorite_border,
                      color: Colors.white70,
                    ),
                    onPressed: () {},
                    tooltip: 'Add to Favorites',
                  ),
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.white70),
                    onPressed: () {},
                    tooltip: 'Share',
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.flag_outlined,
                      color: Colors.white70,
                    ),
                    onPressed: () {},
                    tooltip: 'Report Issue',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSidebarArea() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Video Info Card
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2332),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF232F48)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.args?.title ??
                    _currentPlayingEpisode?.name ??
                    'Unknown Title',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232F48),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'TV-14',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '2024',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.circle, size: 4, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Text(
                    'Sci-Fi',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const Spacer(),
                  const Icon(Icons.star, color: Colors.amber, size: 16),
                  const SizedBox(width: 4),
                  const Text(
                    '8.7',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'More details and synopsis can be placed here if fetched from the provider. For now, it plays the selected media.',
                style: TextStyle(
                  color: Colors.white70,
                  height: 1.5,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Episodes Placeholder Card
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2332),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF232F48)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Episodes',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _groupKeys.isEmpty
                      ? const Center(
                          child: Text(
                            'No episodes found',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : SingleChildScrollView(
                          child: GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 5,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                  childAspectRatio: 1,
                                ),
                            itemCount: _groupKeys.length,
                            itemBuilder: (context, index) {
                              final key = _groupKeys[index];
                              final isPlaying = key == _currentGroupKey;
                              final episodesInGroup =
                                  _groupedEpisodes[key] ?? [];
                              final baseEpisode = episodesInGroup.firstOrNull;

                              return InkWell(
                                onTap: () {
                                  if (episodesInGroup.isNotEmpty &&
                                      !isPlaying) {
                                    _playParsedEpisode(
                                      PreparedEpisodeSelection(
                                        request: widget.args!.shareRequest!,
                                        showDirName:
                                            '', // not fully needed here
                                        episodes: _allEpisodes
                                            .map(
                                              (e) => EpisodeCandidate(
                                                fileId: e.id,
                                                name: e.name,
                                                selectedByDefault: false,
                                              ),
                                            )
                                            .toList(),
                                        preferredFileId: null,
                                        shareEpisodeMap: {
                                          for (var e in _allEpisodes)
                                            e.id: e.file,
                                        },
                                      ),
                                      episodesInGroup.first,
                                    );
                                  }
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isPlaying
                                        ? const Color(0xFFF47B25)
                                        : const Color(0xFF101622),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isPlaying
                                          ? Colors.transparent
                                          : const Color(0xFF2E3B56),
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: isPlaying
                                      ? const Icon(
                                          Icons.equalizer,
                                          color: Colors.white,
                                          size: 20,
                                        )
                                      : FittedBox(
                                          child: Padding(
                                            padding: const EdgeInsets.all(4.0),
                                            child: Text(
                                              baseEpisode?.displayTitle ??
                                                  '${index + 1}',
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF101622),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFF47B25)),
              const SizedBox(height: 16),
              Text(
                _currentPlayingEpisode?.displayTitle != null
                    ? 'Loading ${_currentPlayingEpisode!.displayTitle}...'
                    : 'Preparing playback...',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF101622),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF101622),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopNavigation(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: _buildVideoPlayerArea()),
                    const SizedBox(width: 24),
                    SizedBox(width: 400, child: _buildSidebarArea()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

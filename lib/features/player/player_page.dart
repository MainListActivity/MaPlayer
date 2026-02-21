import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/media_kit_player_controller.dart';
import 'package:ma_palyer/features/player/proxy/proxy_controller.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/playback/media_file_parser.dart';
import 'package:ma_palyer/features/player/vertical_volume_button.dart';

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

  Map<String, List<ParsedMediaInfo>> _groupedEpisodes = {};
  List<String> _groupKeys = []; // Ordered group keys (e.g. "Season-Episode")
  PreparedEpisodeSelection? _preparedSelection;

  String? _currentGroupKey;
  ParsedMediaInfo? _currentPlayingEpisode;
  PlayableMedia? _currentMedia;
  QuarkPlayableVariant? _currentCloudVariant;

  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<ProxyStatsSnapshot>? _proxyStatsSub;
  String? _proxySessionId;
  bool _isBufferingNow = false;
  String _networkSpeedLabel = '--';
  String _bufferAheadLabel = '预读: --';
  String _proxyModeLabel = '';

  @override
  void initState() {
    super.initState();
    _playerController = MediaKitPlayerController();
    _videoController = VideoController(_playerController.player);
    _orchestrator = SharePlayOrchestrator();
    _bindPlayerStreams();

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
    _bufferingSub?.cancel();
    _proxyStatsSub?.cancel();
    final sessionId = _proxySessionId;
    if (sessionId != null) {
      unawaited(ProxyController.instance.closeSession(sessionId));
    }
    unawaited(ProxyController.instance.dispose());
    _playerController.dispose();
    super.dispose();
  }

  void _bindPlayerStreams() {
    final player = _playerController.player;
    _bufferingSub = player.stream.buffering.listen((value) {
      if (!mounted) return;
      setState(() {
        _isBufferingNow = value;
      });
    });
  }

  void _bindProxyStats(String? sessionId) {
    _proxyStatsSub?.cancel();
    if (sessionId == null) {
      if (!mounted) return;
      setState(() {
        _networkSpeedLabel = '--';
        _bufferAheadLabel = '预读: --';
        _proxyModeLabel = '';
      });
      return;
    }
    _proxyStatsSub = ProxyController.instance.watchStats(sessionId).listen((s) {
      if (!mounted) return;
      setState(() {
        _networkSpeedLabel = _formatBitsPerSecond(s.downloadBps);
        _bufferAheadLabel = '预读: ${_formatBytes(s.bufferedBytesAhead)}';
        _proxyModeLabel = s.mode == ProxyMode.parallel ? '并发' : '单连接';
      });
    });
  }

  String _formatBitsPerSecond(double bps) {
    if (bps >= 1000 * 1000) {
      return '${(bps / 1000 / 1000).toStringAsFixed(2)} Mbps';
    }
    if (bps >= 1000) {
      return '${(bps / 1000).toStringAsFixed(1)} Kbps';
    }
    return '${bps.toStringAsFixed(0)} bps';
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
        _groupedEpisodes = grouped;
        _groupKeys = keys.toList();
        _preparedSelection = prepared;
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
        _currentCloudVariant =
            media.selectedVariant ?? media.variants.firstOrNull;
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
    final prepared = _preparedSelection;
    if (prepared == null) return;
    if (_currentGroupKey == null ||
        _groupedEpisodes[_currentGroupKey] == null) {
      return;
    }

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
                      _playParsedEpisode(prepared, ep);
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

  void _showCloudResolutionPicker() {
    final media = _currentMedia;
    if (media == null || media.variants.isEmpty) return;
    final variants = media.variants;
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
                  '网盘清晰度',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const Divider(color: Color(0xFF2E3B56), height: 1),
              ...variants.map((variant) {
                final isCurrent = variant.url == _currentCloudVariant?.url;
                return ListTile(
                  title: Text(
                    _cloudResolutionLabel(variant),
                    style: TextStyle(
                      color: isCurrent ? const Color(0xFFF47B25) : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    _cloudResolutionMeta(variant),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  trailing: isCurrent
                      ? const Icon(Icons.check, color: Color(0xFFF47B25))
                      : null,
                  onTap: () async {
                    Navigator.pop(ctx);
                    if (!isCurrent) {
                      await _switchCloudResolution(variant);
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

  Future<void> _switchCloudResolution(QuarkPlayableVariant variant) async {
    final media = _currentMedia;
    if (media == null) return;
    setState(() {
      _isLoading = true;
      _currentCloudVariant = variant;
    });
    try {
      await _openMedia(
        PlayableMedia(
          url: variant.url,
          headers: variant.headers.isNotEmpty ? variant.headers : media.headers,
          subtitle: media.subtitle,
          progressKey: media.progressKey,
          variants: media.variants,
          selectedVariant: variant,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '切换网盘清晰度失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _cloudResolutionLabel(QuarkPlayableVariant variant) {
    final resolution = variant.resolution.toUpperCase();
    if (resolution == 'UNKNOWN') {
      return '未知清晰度';
    }
    return resolution;
  }

  String _cloudResolutionMeta(QuarkPlayableVariant variant) {
    final parts = <String>[];
    if (variant.sizeBytes != null && variant.sizeBytes! > 0) {
      parts.add(_formatBytes(variant.sizeBytes!));
    }
    if ((variant.width ?? 0) > 0 && (variant.height ?? 0) > 0) {
      parts.add('${variant.width}x${variant.height}');
    }
    final audioCodec = variant.audioCodec?.trim();
    if (audioCodec != null && audioCodec.isNotEmpty) {
      parts.add('音频:${audioCodec.toUpperCase()}');
    } else {
      parts.add('音频:未知');
    }
    return parts.join(' · ');
  }

  String _formatBytes(int bytes) {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final fixed = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$fixed ${units[unitIndex]}';
  }

  Future<void> _openMedia(PlayableMedia media) async {
    setState(() {
      _isLoading = true;
      _currentMedia = media;
      _currentCloudVariant =
          media.selectedVariant ?? media.variants.firstOrNull;
    });
    try {
      final endpoint = await ProxyController.instance.createSession(
        media,
        fileKey: media.progressKey,
      );
      final prevSessionId = _proxySessionId;
      final currentSessionId = endpoint.proxySession?.sessionId;
      _proxySessionId = currentSessionId;
      _bindProxyStats(currentSessionId);
      // For URLs that bypass the proxy (m3u8, non-mp4), pass auth headers
      // directly to media_kit so it can authenticate with the CDN.
      final playHeaders =
          currentSessionId == null ? media.headers : null;
      await _playerController.open(endpoint.playbackUrl, headers: playHeaders);
      if (prevSessionId != null && prevSessionId != currentSessionId) {
        // Delay old session cleanup to avoid cutting off in-flight reads while
        // player backend is still switching URLs.
        unawaited(
          Future<void>.delayed(const Duration(seconds: 3), () async {
            await ProxyController.instance.closeSession(prevSessionId);
          }),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '播放失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showEpisodesDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      useRootNavigator: true,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: const Color(0xFF1A2332),
            child: SizedBox(
              width: 400,
              height: double.infinity,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '播放详情',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                            onPressed: () => Navigator.of(dialogContext).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: _buildSidebarArea(
                          onEpisodeSelected: () {
                            Navigator.of(dialogContext).pop();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        );
      },
    );
  }

  List<Widget> _buildTopButtonBar() {
    return [
      if (_currentPlayingEpisode != null)
        Container(
          margin: const EdgeInsets.only(top: 16, left: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2332).withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2E3B56)),
          ),
          child: Text(
            _currentPlayingEpisode!.displayTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      const Spacer(),
      Container(
        margin: const EdgeInsets.only(top: 16, right: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2332).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isBufferingNow
                ? const Color(0xFFF47B25)
                : const Color(0xFF2E3B56),
          ),
        ),
        child: Text(
          '网速: $_networkSpeedLabel  ·  $_bufferAheadLabel'
          '${_proxyModeLabel.isEmpty ? '' : '  ·  $_proxyModeLabel'}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildBottomButtonBar() {
    return [
      const MaterialDesktopSkipPreviousButton(),
      const MaterialDesktopPlayOrPauseButton(),
      const MaterialDesktopSkipNextButton(),
      const VerticalVolumeButton(iconSize: 24),
      MaterialDesktopCustomButton(
        onPressed: _showEpisodesDialog,
        icon: const Icon(Icons.format_list_bulleted),
      ),
      const SizedBox(width: 8),
      const MaterialDesktopPositionIndicator(),
      const Spacer(),
      const MaterialDesktopFullscreenButton(),
    ];
  }

  Widget _buildTopNavigation() {
    // On macOS, reserve space for the traffic light buttons (close/minimize/maximize)
    final isMacOS = Platform.isMacOS;
    return Container(
      height: 52,
      padding: EdgeInsets.only(left: isMacOS ? 78 : 16, right: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1219),
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFF232F48).withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // Back button + Logo (tappable as a unit)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              final navigator = Navigator.of(context);
              final popped = await navigator.maybePop();
              if (!popped && mounted) {
                navigator.pushReplacementNamed(AppRoutes.home);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  SvgPicture.asset(
                    'logo/ma_player_logo.svg',
                    width: 28,
                    height: 28,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Ma Player',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // Compact pill search bar
          Container(
            width: 180,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF151D2B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF232F48).withValues(alpha: 0.6),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.search_rounded, color: Color(0xFF5A6F8E), size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      hintStyle: TextStyle(
                        color: Color(0xFF5A6F8E),
                        fontSize: 12,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Avatar with orange gradient
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFFF47B25), Color(0xFFE85D04)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Icon(Icons.person, size: 16, color: Colors.white),
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
            child: MaterialDesktopVideoControlsTheme(
              normal: MaterialDesktopVideoControlsThemeData(
                topButtonBar: _buildTopButtonBar(),
                bottomButtonBar: _buildBottomButtonBar(),
              ),
              fullscreen: MaterialDesktopVideoControlsThemeData(
                topButtonBar: _buildTopButtonBar(),
                bottomButtonBar: _buildBottomButtonBar(),
              ),
              child: Video(controller: _videoController),
            ),
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
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 12,
            spacing: 12,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
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
                  OutlinedButton.icon(
                    onPressed: _currentMedia?.variants.isNotEmpty == true
                        ? _showCloudResolutionPicker
                        : null,
                    icon: const Icon(
                      Icons.high_quality_rounded,
                      size: 18,
                      color: Color(0xFFF47B25),
                    ),
                    label: Text(
                      _currentCloudVariant != null
                          ? _cloudResolutionLabel(_currentCloudVariant!)
                          : '网盘清晰度',
                      style: const TextStyle(color: Colors.white),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF2E3B56)),
                      backgroundColor: const Color(0xFF101622),
                    ),
                  ),
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
              Wrap(
                spacing: 4,
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

  Widget _buildSidebarArea({VoidCallback? onEpisodeSelected}) {
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
                                  final prepared = _preparedSelection;
                                  if (prepared == null) return;
                                  if (episodesInGroup.isNotEmpty &&
                                      !isPlaying) {
                                    if (onEpisodeSelected != null) {
                                      onEpisodeSelected();
                                    }
                                    _playParsedEpisode(
                                      prepared,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showSidebar = constraints.maxWidth >= 1000;
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildVideoPlayerArea()),
                        if (showSidebar) ...[
                          const SizedBox(width: 24),
                          SizedBox(width: 400, child: _buildSidebarArea()),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

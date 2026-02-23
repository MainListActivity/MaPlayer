import 'dart:async';
import 'dart:io' show HttpHeaders, Platform;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_login_webview_page.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/media_kit_player_controller.dart';
import 'package:ma_palyer/features/player/proxy/proxy_controller.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';
import 'package:ma_palyer/features/playback/media_file_parser.dart';
import 'package:ma_palyer/features/player/vertical_volume_button.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';

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
  late final QuarkAuthService _quarkAuthService;
  final _historyRepository = PlayHistoryRepository();

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
  StreamSubscription<PlayerLog>? _playerLogSub;
  StreamSubscription<String>? _playerErrorSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<ProxyAggregateStats>? _proxyStatsSub;
  String? _proxySessionId;
  Future<Map<String, String>?>? _pendingProxyAuthRecovery;
  bool _isRecoveringMediaKitAuth = false;
  String? _lastMediaKitAuthRecoverKey;
  DateTime? _lastMediaKitAuthRecoverAt;
  bool _isBufferingNow = false;
  String _networkSpeedLabel = '--';
  String _bufferAheadLabel = '预读: --';
  String _proxyModeLabel = '';

  void _log(String message) => debugPrint('[PlayerPage] $message');

  @override
  void initState() {
    super.initState();
    _playerController = MediaKitPlayerController();
    _videoController = VideoController(_playerController.player);
    _quarkAuthService = QuarkAuthService();
    _orchestrator = SharePlayOrchestrator(authService: _quarkAuthService);
    _bindPlayerStreams();
    _bindProxyStats();

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
    _completedSub?.cancel();
    _playerLogSub?.cancel();
    _playerErrorSub?.cancel();
    _proxyStatsSub?.cancel();
    final sessionId = _proxySessionId;
    if (sessionId != null) {
      unawaited(ProxyController.instance.closeSession(sessionId));
    }
    unawaited(ProxyController.instance.dispose());
    // Save playback position
    final prepared = _preparedSelection;
    final currentEpisode = _currentPlayingEpisode;
    if (prepared != null && currentEpisode != null) {
      final posMs = _playerController.player.state.position.inMilliseconds;
      if (posMs > 0) {
        final disposeAtMs = DateTime.now().millisecondsSinceEpoch;
        unawaited(
          _savePlaybackPosition(
            shareUrl: prepared.request.shareUrl,
            positionMs: posMs,
            disposeAtMs: disposeAtMs,
          ),
        );
      }
    }
    _playerController.dispose();
    super.dispose();
  }

  Future<void> _savePlaybackPosition({
    required String shareUrl,
    required int positionMs,
    required int disposeAtMs,
  }) async {
    try {
      final current = await _historyRepository.findByShareUrl(shareUrl);
      if (current == null) return;
      // Skip if a newer session has already updated this history entry.
      if (current.updatedAtEpochMs > disposeAtMs) return;
      await _historyRepository.upsertByShareUrl(
        current.copyWith(
          lastPositionMs: positionMs,
          updatedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      debugPrint('[PlayerPage] Failed to save playback position: $e');
    }
  }

  void _bindPlayerStreams() {
    final player = _playerController.player;
    _bufferingSub = player.stream.buffering.listen((value) {
      if (!mounted) return;
      setState(() {
        _isBufferingNow = value;
      });
    });
    _completedSub = player.stream.completed.listen((value) {
      if (!mounted) return;
      if (value) {
        _playNextEpisode();
      }
    });
    _playerLogSub = player.stream.log.listen((event) {
      final message = '${event.prefix} ${event.text}'.trim();
      if (message.isNotEmpty) {
        _log('media_kit log: $message');
      }
      if (!_isAuthRejectedHttpMessage(message)) return;
      unawaited(_handleMediaKitAuthRejected(message));
    });
    _playerErrorSub = player.stream.error.listen((message) {
      _log('media_kit error: $message');
      if (!_isAuthRejectedHttpMessage(message)) return;
      unawaited(_handleMediaKitAuthRejected(message));
    });
  }

  void _bindProxyStats() {
    _proxyStatsSub?.cancel();
    _proxyStatsSub = ProxyController.instance.watchAggregateStats().listen((s) {
      if (!mounted) return;
      setState(() {
        if (!s.proxyRunning) {
          _networkSpeedLabel = '--';
          _bufferAheadLabel = '预读: --';
          _proxyModeLabel = '';
          return;
        }
        _networkSpeedLabel = _formatBitsPerSecond(s.downloadBps);
        _bufferAheadLabel = '预读: ${_formatBytes(s.bufferedBytesAhead)}';
        _proxyModeLabel = s.activeWorkers > 0 ? '并发: ${s.activeWorkers}' : '';
      });
    });
  }

  /// Waits for media_kit to report a non-zero duration, up to [timeout].
  /// Returns Duration.zero on timeout.
  Future<Duration> _waitForDuration({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final current = _playerController.player.state.duration;
    if (current > Duration.zero) return current;
    final completer = Completer<Duration>();
    late StreamSubscription<Duration> sub;
    sub = _playerController.player.stream.duration.listen((d) {
      if (d > Duration.zero) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete(d);
      }
    });
    Future<void>.delayed(timeout).then((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete(Duration.zero);
    });
    return completer.future;
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

  String _networkStatsText() {
    return '网速: $_networkSpeedLabel  ·  $_bufferAheadLabel'
        '${_proxyModeLabel.isEmpty ? '' : '  ·  $_proxyModeLabel'}';
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
        final seasonA = a.season ?? -1;
        final seasonB = b.season ?? -1;
        if (seasonA != seasonB) {
          return seasonA.compareTo(seasonB);
        }
        final epA = a.episode ?? -1;
        final epB = b.episode ?? -1;
        if (epA != epB) {
          return epA.compareTo(epB);
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
        _currentCloudVariant = _defaultCloudVariant(media);
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

  void _playNextEpisode() {
    final prepared = _preparedSelection;
    if (prepared == null || _currentGroupKey == null) return;

    final currentIndex = _groupKeys.indexOf(_currentGroupKey!);
    if (currentIndex >= 0 && currentIndex + 1 < _groupKeys.length) {
      final nextKey = _groupKeys[currentIndex + 1];
      final nextEpisodes = _groupedEpisodes[nextKey];
      if (nextEpisodes != null && nextEpisodes.isNotEmpty) {
        final currentRes = _currentPlayingEpisode?.resolution;
        ParsedMediaInfo? toPlay = nextEpisodes.first;
        if (currentRes != null) {
          final matched = nextEpisodes
              .where((e) => e.resolution == currentRes)
              .firstOrNull;
          if (matched != null) toPlay = matched;
        }
        _playParsedEpisode(prepared, toPlay);
      }
    }
  }

  void _playPreviousEpisode() {
    final prepared = _preparedSelection;
    if (prepared == null || _currentGroupKey == null) return;

    final currentIndex = _groupKeys.indexOf(_currentGroupKey!);
    if (currentIndex > 0) {
      final prevKey = _groupKeys[currentIndex - 1];
      final prevEpisodes = _groupedEpisodes[prevKey];
      if (prevEpisodes != null && prevEpisodes.isNotEmpty) {
        final currentRes = _currentPlayingEpisode?.resolution;
        ParsedMediaInfo? toPlay = prevEpisodes.first;
        if (currentRes != null) {
          final matched = prevEpisodes
              .where((e) => e.resolution == currentRes)
              .firstOrNull;
          if (matched != null) toPlay = matched;
        }
        _playParsedEpisode(prepared, toPlay);
      }
    }
  }

  bool _hasNextEpisode() {
    if (_preparedSelection == null || _currentGroupKey == null) return false;
    final currentIndex = _groupKeys.indexOf(_currentGroupKey!);
    return currentIndex >= 0 && currentIndex + 1 < _groupKeys.length;
  }

  bool _hasPreviousEpisode() {
    if (_preparedSelection == null || _currentGroupKey == null) return false;
    final currentIndex = _groupKeys.indexOf(_currentGroupKey!);
    return currentIndex > 0;
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
    final variants = _cloudVariantsForDisplay(media.variants);
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
    // Capture current position before opening new media, so we can restore it
    // after the switch (instead of seeking to the historically saved position).
    final currentPositionMs =
        _playerController.player.state.position.inMilliseconds;
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
      // Restore the live position after switching resolution.
      if (mounted && currentPositionMs > 0) {
        final duration = _playerController.player.state.duration > Duration.zero
            ? _playerController.player.state.duration
            : await _waitForDuration();
        if (mounted && duration > Duration.zero) {
          await _playerController.player.seek(
            Duration(
              milliseconds: currentPositionMs.clamp(0, duration.inMilliseconds),
            ),
          );
        }
      }
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
      _currentCloudVariant = _defaultCloudVariant(media);
    });
    try {
      final shouldUseProxy = _shouldUseProxy(media);
      _log('open media shouldUseProxy=$shouldUseProxy url=${media.url}');
      final endpoint = shouldUseProxy
          ? await ProxyController.instance.createSession(
              media,
              fileKey: media.progressKey,
              onSourceAuthRejected: _handleProxySourceAuthRejected,
            )
          : ResolvedPlaybackEndpoint(
              originalMedia: media,
              playbackUrl: media.url,
            );
      _log(
        'resolved playback url=${endpoint.playbackUrl}, session=${endpoint.proxySession?.sessionId ?? "none"}',
      );
      final prevSessionId = _proxySessionId;
      final currentSessionId = endpoint.proxySession?.sessionId;
      _proxySessionId = currentSessionId;
      // For URLs that bypass the proxy (m3u8, non-mp4), pass auth headers
      // directly to media_kit so it can authenticate with the CDN.
      final playHeaders = currentSessionId == null ? media.headers : null;
      _log(
        'player.open url=${endpoint.playbackUrl}, headers=${playHeaders?.length ?? 0}',
      );
      await _playerController.open(endpoint.playbackUrl, headers: playHeaders);
      // Seek to restored playback position if available.
      final restoredBytes = currentSessionId != null
          ? ProxyController.instance.getRestoredPosition(currentSessionId)
          : null;
      var didByteSeek = false;
      if (restoredBytes != null && restoredBytes > 0) {
        final contentLength = endpoint.proxySession?.contentLength;
        if (contentLength != null && contentLength > 0) {
          final duration = await _waitForDuration();
          if (!mounted) return;
          if (duration > Duration.zero) {
            final seekFraction = restoredBytes / contentLength;
            final seekTo = duration * seekFraction;
            await _playerController.player.seek(seekTo);
            didByteSeek = true;
          }
        }
      }
      // Restore time-based playback position from history.
      // Only seek when the currently opening episode matches the last-played episode in history.
      if (!didByteSeek) {
        final prepared = _preparedSelection;
        final currentEpisode = _currentPlayingEpisode;
        if (prepared != null && currentEpisode != null) {
          final history = await _historyRepository.findByShareUrl(
            prepared.request.shareUrl,
          );
          final posMs = history?.lastPositionMs ?? 0;
          if (posMs > 0 &&
              history?.lastEpisodeFileId == currentEpisode.file.fid) {
            final duration =
                _playerController.player.state.duration > Duration.zero
                ? _playerController.player.state.duration
                : await _waitForDuration();
            if (!mounted) return;
            if (duration > Duration.zero) {
              final seekTo = Duration(
                milliseconds: posMs.clamp(0, duration.inMilliseconds),
              );
              await _playerController.player.seek(seekTo);
            }
          }
        }
      }
      if (prevSessionId != null && prevSessionId != currentSessionId) {
        // Stop previous download workers immediately on media switch.
        unawaited(ProxyController.instance.closeSession(prevSessionId));
      }
    } catch (e) {
      _log('open media failed: $e');
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

  bool _shouldUseProxy(PlayableMedia media) {
    final resolution = media.selectedVariant?.resolution.toLowerCase().trim();
    if (resolution != null &&
        (resolution == 'raw' || resolution.contains('raw'))) {
      return true;
    }
    final url = media.url.toLowerCase();
    return url.contains('/file/download');
  }

  QuarkPlayableVariant? _defaultCloudVariant(PlayableMedia media) {
    if (media.selectedVariant != null) {
      return media.selectedVariant;
    }
    if (media.variants.isEmpty) {
      return null;
    }
    const preferred = <String>['4k', '2k', 'super', 'high', 'normal', 'low'];
    for (final resolution in preferred) {
      for (final variant in media.variants) {
        if (variant.resolution.toLowerCase() == resolution) {
          return variant;
        }
      }
    }
    for (final variant in media.variants) {
      if (variant.resolution.toLowerCase() != 'raw') {
        return variant;
      }
    }
    return media.variants.first;
  }

  List<QuarkPlayableVariant> _cloudVariantsForDisplay(
    List<QuarkPlayableVariant> variants,
  ) {
    final raw = <QuarkPlayableVariant>[];
    final rest = <QuarkPlayableVariant>[];
    for (final variant in variants) {
      if (variant.resolution.toLowerCase() == 'raw') {
        raw.add(variant);
      } else {
        rest.add(variant);
      }
    }
    return <QuarkPlayableVariant>[...raw, ...rest];
  }

  bool _isAuthRejectedHttpMessage(String message) {
    final lower = message.toLowerCase();
    return lower.contains('http error 412') ||
        lower.contains('412 precondition failed') ||
        lower.contains('http error 401') ||
        lower.contains('http error 403') ||
        lower.contains(' 401 unauthorized') ||
        lower.contains(' 403 forbidden');
  }

  String _mediaRecoverKey(PlayableMedia media) {
    return '${media.progressKey}:${media.url}';
  }

  bool _canTriggerMediaKitAuthRecover(PlayableMedia media) {
    if (_isRecoveringMediaKitAuth) return false;
    final key = _mediaRecoverKey(media);
    final lastAt = _lastMediaKitAuthRecoverAt;
    if (_lastMediaKitAuthRecoverKey == key &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 20)) {
      return false;
    }
    return true;
  }

  Future<void> _handleMediaKitAuthRejected(String message) async {
    final media = _currentMedia;
    if (!mounted || media == null || !_isLikelyQuarkMedia(media)) return;
    if (!_canTriggerMediaKitAuthRecover(media)) return;
    final key = _mediaRecoverKey(media);
    _isRecoveringMediaKitAuth = true;
    _lastMediaKitAuthRecoverKey = key;
    _lastMediaKitAuthRecoverAt = DateTime.now();
    try {
      if (mounted) {
        setState(() {
          _errorMessage = '检测到网盘鉴权失效(HTTP 412/401/403)，正在重新认证...';
        });
      }
      final nextHeaders = await _handleProxySourceAuthRejected();
      if (!mounted || nextHeaders == null || nextHeaders.isEmpty) return;
      final current = _currentMedia;
      if (current == null) return;
      if (_mediaRecoverKey(current) != key) return;
      await _openMedia(
        PlayableMedia(
          url: current.url,
          headers: nextHeaders,
          subtitle: current.subtitle,
          progressKey: current.progressKey,
          variants: current.variants,
          selectedVariant: current.selectedVariant,
        ),
      );
    } catch (_) {
      // _openMedia already handles user-visible errors.
    } finally {
      _isRecoveringMediaKitAuth = false;
    }
  }

  Future<Map<String, String>?> _handleProxySourceAuthRejected() {
    final pending = _pendingProxyAuthRecovery;
    if (pending != null) {
      return pending;
    }
    final future = _runProxySourceAuthRecovery();
    _pendingProxyAuthRecovery = future;
    future.whenComplete(() {
      if (identical(_pendingProxyAuthRecovery, future)) {
        _pendingProxyAuthRecovery = null;
      }
    });
    return future;
  }

  Future<Map<String, String>?> _runProxySourceAuthRecovery() async {
    final media = _currentMedia;
    if (!mounted || media == null || !_isLikelyQuarkMedia(media)) {
      return null;
    }
    final recovered = await QuarkLoginWebviewPage.recoverAuth(
      context,
      _quarkAuthService,
    );
    if (!recovered) {
      return null;
    }
    final nextHeaders = await _refreshHeadersFromAuth(media.headers);
    if (nextHeaders == null || nextHeaders.isEmpty) {
      return null;
    }
    if (mounted) {
      setState(() {
        final current = _currentMedia;
        if (current != null) {
          _currentMedia = PlayableMedia(
            url: current.url,
            headers: nextHeaders,
            subtitle: current.subtitle,
            progressKey: current.progressKey,
            variants: current.variants,
            selectedVariant: current.selectedVariant,
          );
        }
      });
    }
    return nextHeaders;
  }

  Future<Map<String, String>?> _refreshHeadersFromAuth(
    Map<String, String> currentHeaders,
  ) async {
    final state = await _quarkAuthService.currentAuthState();
    final cookie = state?.cookie?.trim() ?? '';
    if (cookie.isEmpty) return null;
    final next = Map<String, String>.from(currentHeaders);
    _setHeaderCaseInsensitive(next, HttpHeaders.cookieHeader, cookie);
    if (_getHeaderCaseInsensitive(next, HttpHeaders.refererHeader) == null) {
      next[HttpHeaders.refererHeader] = 'https://pan.quark.cn/';
    }
    return next;
  }

  bool _isLikelyQuarkMedia(PlayableMedia media) {
    final url = media.url.toLowerCase();
    if (url.contains('quark.cn')) return true;
    final referer =
        _getHeaderCaseInsensitive(
          media.headers,
          HttpHeaders.refererHeader,
        )?.toLowerCase() ??
        '';
    return referer.contains('quark.cn');
  }

  String? _getHeaderCaseInsensitive(Map<String, String> headers, String key) {
    final target = key.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) {
        return entry.value;
      }
    }
    return null;
  }

  void _setHeaderCaseInsensitive(
    Map<String, String> headers,
    String key,
    String value,
  ) {
    final target = key.toLowerCase();
    String? matchedKey;
    for (final existingKey in headers.keys) {
      if (existingKey.toLowerCase() == target) {
        matchedKey = existingKey;
        break;
      }
    }
    if (matchedKey != null) {
      headers[matchedKey] = value;
      return;
    }
    headers[key] = value;
  }

  void _showEpisodesDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
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
    ];
  }

  List<Widget> _buildBottomButtonBar() {
    final hasPrev = _hasPreviousEpisode();
    final hasNext = _hasNextEpisode();

    return [
      if (hasPrev)
        MaterialDesktopCustomButton(
          onPressed: _playPreviousEpisode,
          icon: const Icon(Icons.skip_previous),
        ),
      const MaterialDesktopPlayOrPauseButton(),
      if (hasNext)
        MaterialDesktopCustomButton(
          onPressed: _playNextEpisode,
          icon: const Icon(Icons.skip_next),
        ),
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
                      hintText: '搜索...',
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
            child: Stack(
              children: [
                MaterialDesktopVideoControlsTheme(
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
                if (_isBufferingNow)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: IgnorePointer(
                      child: Text(
                        _networkStatsText(),
                        style: const TextStyle(
                          color: Color(0xFFFFB37A),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
              ],
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
                      _currentPlayingEpisode?.displayResolution ?? '线路1',
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
                      '英语',
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
                    tooltip: '加入收藏',
                  ),
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.white70),
                    onPressed: () {},
                    tooltip: '分享',
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.flag_outlined,
                      color: Colors.white70,
                    ),
                    onPressed: () {},
                    tooltip: '问题反馈',
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
    final detailRequest =
        _preparedSelection?.request ?? widget.args?.shareRequest;
    final title = (detailRequest?.title.trim().isNotEmpty ?? false)
        ? detailRequest!.title.trim()
        : (widget.args?.title ?? _currentPlayingEpisode?.name ?? '未知标题');
    final year = detailRequest?.year?.trim() ?? '';
    final category = detailRequest?.category?.trim() ?? '';
    final rating = detailRequest?.rating?.trim() ?? '';
    final intro = detailRequest?.intro?.trim() ?? '';
    final hasMeta = year.isNotEmpty || category.isNotEmpty || rating.isNotEmpty;
    final metaLeftWidgets = <Widget>[];
    void appendMetaText(String value) {
      if (metaLeftWidgets.isNotEmpty) {
        metaLeftWidgets.add(const SizedBox(width: 8));
        metaLeftWidgets.add(
          const Icon(Icons.circle, size: 4, color: Colors.white54),
        );
        metaLeftWidgets.add(const SizedBox(width: 8));
      }
      metaLeftWidgets.add(
        Text(
          value,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      );
    }

    if (year.isNotEmpty) {
      appendMetaText(year);
    }
    if (category.isNotEmpty) {
      appendMetaText(category);
    }

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
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  height: 1.2,
                ),
              ),
              if (hasMeta) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    ...metaLeftWidgets,
                    if (rating.isNotEmpty) ...[
                      if (metaLeftWidgets.isNotEmpty) const Spacer(),
                      const Icon(Icons.star, color: Colors.amber, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        rating,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              if (intro.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  intro,
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.5,
                    fontSize: 13,
                  ),
                ),
              ],
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
                  '剧集列表',
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
                            '未找到剧集',
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

  Widget _buildPortraitBody() {
    return CustomScrollView(
      slivers: [
        // ── Video ──────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                children: [
                  MaterialDesktopVideoControlsTheme(
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
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () async {
                          final navigator = Navigator.of(context);
                          final popped = await navigator.maybePop();
                          if (!popped && mounted) {
                            navigator.pushReplacementNamed(AppRoutes.home);
                          }
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isBufferingNow)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: IgnorePointer(
                        child: Text(
                          _networkStatsText(),
                          style: const TextStyle(
                            color: Color(0xFFFFB37A),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // ── Controls ───────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _showResolutionPicker,
                  icon: const Icon(
                    Icons.dns,
                    size: 16,
                    color: Color(0xFFF47B25),
                  ),
                  label: Text(
                    _currentPlayingEpisode?.displayResolution ?? '线路1',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    side: const BorderSide(color: Color(0xFF2E3B56)),
                    backgroundColor: const Color(0xFF101622),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _currentMedia?.variants.isNotEmpty == true
                      ? _showCloudResolutionPicker
                      : null,
                  icon: const Icon(
                    Icons.high_quality_rounded,
                    size: 16,
                    color: Color(0xFFF47B25),
                  ),
                  label: Text(
                    _currentCloudVariant != null
                        ? _cloudResolutionLabel(_currentCloudVariant!)
                        : '网盘清晰度',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    side: const BorderSide(color: Color(0xFF2E3B56)),
                    backgroundColor: const Color(0xFF101622),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.favorite_border,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () {},
                  tooltip: '加入收藏',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.share,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () {},
                  tooltip: '分享',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(6),
                ),
              ],
            ),
          ),
        ),
        // ── Episode grid ───────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(color: Color(0xFF232F48)),
                const SizedBox(height: 8),
                const Text(
                  '剧集列表',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                if (_groupKeys.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '未找到剧集',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1,
                        ),
                    itemCount: _groupKeys.length,
                    itemBuilder: (context, index) {
                      final key = _groupKeys[index];
                      final isPlaying = key == _currentGroupKey;
                      final episodesInGroup = _groupedEpisodes[key] ?? [];
                      final baseEpisode = episodesInGroup.firstOrNull;

                      return InkWell(
                        onTap: () {
                          final prepared = _preparedSelection;
                          if (prepared == null) return;
                          if (episodesInGroup.isNotEmpty && !isPlaying) {
                            _playParsedEpisode(prepared, episodesInGroup.first);
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isPlaying
                                ? const Color(0xFFF47B25)
                                : const Color(0xFF1A2332),
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
                    ? '正在加载 ${_currentPlayingEpisode!.displayTitle}...'
                    : '正在准备播放...',
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
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    final isPortrait = size.width < size.height && size.width < 600;

    if (isPortrait) {
      return Scaffold(
        backgroundColor: const Color(0xFF101622),
        body: SafeArea(child: _buildPortraitBody()),
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

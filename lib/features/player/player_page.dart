import 'package:flutter/material.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/playback/playback_orchestrator.dart';
import 'package:ma_palyer/features/player/media_kit_player_controller.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _sourceKeyController = TextEditingController();
  final _playFlagController = TextEditingController(text: 'quark');
  final _episodeUrlController = TextEditingController();

  late final MediaKitPlayerController _playerController;
  late final VideoController _videoController;
  late final QuarkAuthService _quarkAuthService;
  late final PlaybackOrchestrator _orchestrator;

  String _statusText = '待命';
  bool _isLoading = false;
  QuarkQrSession? _qrSession;
  PlayableMedia? _lastMedia;

  @override
  void initState() {
    super.initState();
    _playerController = MediaKitPlayerController();
    _videoController = VideoController(_playerController.player);
    _quarkAuthService = QuarkAuthService();
    _orchestrator = PlaybackOrchestrator(quarkAuthService: _quarkAuthService);
  }

  @override
  void dispose() {
    _sourceKeyController.dispose();
    _playFlagController.dispose();
    _episodeUrlController.dispose();
    _playerController.dispose();
    super.dispose();
  }

  Future<void> _resolveAndPlay() async {
    final sourceKey = _sourceKeyController.text.trim();
    final playFlag = _playFlagController.text.trim();
    final episodeUrl = _episodeUrlController.text.trim();
    if (sourceKey.isEmpty || playFlag.isEmpty || episodeUrl.isEmpty) {
      setState(() {
        _statusText = '请填写 sourceKey / playFlag / episodeUrl';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _statusText = '正在解析播放信息...';
      _qrSession = null;
    });

    try {
      final result = await _orchestrator.resolve(
        PlaybackRequest(
          sourceKey: sourceKey,
          playFlag: playFlag,
          episodeUrl: episodeUrl,
        ),
        onQuarkLoginRequired: () async {
          final session = await _quarkAuthService.createQrSession();
          if (mounted) {
            setState(() {
              _statusText = '请扫码登录夸克';
              _qrSession = session;
            });
          }
          return session;
        },
      );
      _lastMedia = result.media;
      await _playerController.open(
        result.media.url,
        headers: result.media.headers,
      );
      if (!mounted) return;
      setState(() {
        _statusText = '播放就绪: ${result.media.url}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = '解析失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _logoutQuark() async {
    await _quarkAuthService.clearAuthState();
    if (!mounted) return;
    setState(() {
      _statusText = '夸克登录态已清除';
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Playback Debug',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _sourceKeyController,
                      decoration: const InputDecoration(labelText: 'sourceKey'),
                    ),
                  ),
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _playFlagController,
                      decoration: const InputDecoration(labelText: 'playFlag'),
                    ),
                  ),
                  SizedBox(
                    width: 520,
                    child: TextField(
                      controller: _episodeUrlController,
                      decoration: const InputDecoration(
                        labelText:
                            'episodeUrl (e.g. quark://shareRef or http url)',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _resolveAndPlay,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: Text(_isLoading ? '处理中...' : '解析并播放'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _logoutQuark,
                    icon: const Icon(Icons.logout),
                    label: const Text('退出夸克登录'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF192233),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2E3B56)),
                ),
                child: Text('状态: $_statusText'),
              ),
              if (_qrSession != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF192233),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF2E3B56)),
                  ),
                  child: Text('夸克二维码地址: ${_qrSession!.qrCodeUrl}'),
                ),
              ],
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF090D16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF2E3B56)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Video(controller: _videoController),
                ),
              ),
              if (_lastMedia != null) ...[
                const SizedBox(height: 8),
                Text('Current URL: ${_lastMedia!.url}'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

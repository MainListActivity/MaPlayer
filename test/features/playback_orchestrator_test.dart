import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/core/spider/spider_runtime.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_transfer_service.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/playback/playback_orchestrator.dart';

class _FakeSpiderRuntime extends SpiderRuntime {
  _FakeSpiderRuntime(this.instance, this.flags);

  final SpiderInstance instance;
  final List<String> flags;

  @override
  Future<SpiderInstance> getSpider(String sourceKey) async => instance;

  @override
  Future<List<String>> vipFlags() async => flags;
}

class _FakeSpiderInstance implements SpiderInstance {
  _FakeSpiderInstance(this.playerPayload);

  final Map<String, dynamic> playerPayload;

  @override
  String get sourceKey => 'fake';

  @override
  Future<Map<String, dynamic>> homeContent({bool filter = true}) async =>
      <String, dynamic>{'list': const <Map<String, dynamic>>[]};

  @override
  Future<Map<String, dynamic>> categoryContent(
    String categoryId, {
    int page = 1,
    bool filter = true,
    Map<String, dynamic>? extend,
  }) async => <String, dynamic>{'list': const <Map<String, dynamic>>[]};

  @override
  Future<Map<String, dynamic>> detailContent(List<String> ids) async =>
      <String, dynamic>{};

  @override
  Future<void> dispose() async {}

  @override
  Future<Map<String, dynamic>> playerContent(
    String flag,
    String id,
    List<String> vipFlags,
  ) async {
    return playerPayload;
  }

  @override
  Future<Map<String, dynamic>> searchContent(String key, {bool quick = false}) {
    throw UnimplementedError();
  }
}

class _FakeQuarkAuthService extends QuarkAuthService {
  _FakeQuarkAuthService({this.requireLogin = false});

  final bool requireLogin;
  bool polled = false;

  @override
  Future<QuarkAuthState> ensureValidToken() async {
    if (requireLogin && !polled) {
      throw QuarkException('need login', code: 'AUTH_REQUIRED');
    }
    return QuarkAuthState(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAtEpochMs: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
  }

  @override
  Future<QuarkQrSession> createQrSession() async {
    return QuarkQrSession(
      sessionId: 's',
      qrCodeUrl: 'https://qr',
      expiresAt: DateTime.now().add(const Duration(seconds: 8)),
    );
  }

  @override
  Future<QuarkQrPollResult> pollQrLogin(String sessionId) async {
    polled = true;
    return QuarkQrPollResult(
      status: 'confirmed',
      authState: QuarkAuthState(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAtEpochMs: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      ),
    );
  }
}

class _FakeQuarkTransferService extends QuarkTransferService {
  _FakeQuarkTransferService() : super(authService: _FakeQuarkAuthService());

  @override
  Future<QuarkSavedFile> saveShareToMyDrive(
    QuarkShareRef shareRef,
    String targetDir,
  ) async {
    return QuarkSavedFile(
      fileId: 'f1',
      fileName: 'video.mp4',
      parentDir: targetDir,
    );
  }

  @override
  Future<QuarkPlayableFile> resolvePlayableFile(String savedFileId) async {
    return const QuarkPlayableFile(
      url: 'https://video.example.com/stream.m3u8',
      headers: <String, String>{'User-Agent': 'UA'},
      subtitle: 'https://sub.example.com/1.srt',
    );
  }
}

void main() {
  test('resolve direct media from playerContent', () async {
    final orchestrator = PlaybackOrchestrator(
      spiderRuntime: _FakeSpiderRuntime(
        _FakeSpiderInstance(<String, dynamic>{
          'parse': 0,
          'jx': 0,
          'url': 'https://cdn.example.com/video.mp4',
          'playUrl': '',
          'header': '{"Referer":"https://x"}',
        }),
        const <String>[],
      ),
      quarkAuthService: _FakeQuarkAuthService(),
      quarkTransferService: _FakeQuarkTransferService(),
    );

    final result = await orchestrator.resolve(
      const PlaybackRequest(
        sourceKey: 's1',
        playFlag: 'f1',
        episodeUrl: 'https://cdn.example.com/video.mp4',
      ),
    );

    expect(result.media.url, 'https://cdn.example.com/video.mp4');
    expect(result.media.headers['Referer'], 'https://x');
  });

  test('resolve quark media after login challenge', () async {
    final auth = _FakeQuarkAuthService(requireLogin: true);
    final orchestrator = PlaybackOrchestrator(
      spiderRuntime: _FakeSpiderRuntime(
        _FakeSpiderInstance(<String, dynamic>{
          'parse': 0,
          'jx': 0,
          'url': '',
          'quark': <String, dynamic>{'shareRef': 'https://pan.quark.cn/s/mock'},
        }),
        const <String>[],
      ),
      quarkAuthService: auth,
      quarkTransferService: _FakeQuarkTransferService(),
    );

    final result = await orchestrator.resolve(
      const PlaybackRequest(
        sourceKey: 's1',
        playFlag: 'f1',
        episodeUrl: 'quark://mock',
      ),
      onQuarkLoginRequired: () => auth.createQrSession(),
    );

    expect(result.media.url, 'https://video.example.com/stream.m3u8');
    expect(auth.polled, isTrue);
  });
}

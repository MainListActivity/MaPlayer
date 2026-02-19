import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_transfer_service.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';

class _FakeAuthService extends QuarkAuthService {
  @override
  Future<QuarkAuthState> ensureValidToken() async {
    return QuarkAuthState(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAtEpochMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
  }
}

class _FakeTransferService extends QuarkTransferService {
  _FakeTransferService() : super(authService: _FakeAuthService());

  bool transferred = false;
  List<QuarkFileEntry> files = <QuarkFileEntry>[];

  @override
  Future<QuarkFolderLookupResult> findOrCreateShowFolder(String rootDir, String showDirName) async {
    return QuarkFolderLookupResult(
      folderId: 'folder1',
      folderName: showDirName,
      created: false,
      path: '$rootDir/$showDirName',
    );
  }

  @override
  Future<List<QuarkFileEntry>> listFilesInFolder(String folderId) async {
    return files;
  }

  @override
  Future<QuarkSavedFile> saveShareToFolder(QuarkShareRef shareRef, String folderId) async {
    transferred = true;
    files = <QuarkFileEntry>[
      const QuarkFileEntry(fileId: 'e1', fileName: '第1集.mp4', isDirectory: false),
      const QuarkFileEntry(fileId: 'e2', fileName: '第2集.mp4', isDirectory: false),
    ];
    return const QuarkSavedFile(fileId: 'task1', fileName: 'saved', parentDir: '/MaPlayer');
  }

  @override
  Future<QuarkPlayableFile> resolvePlayableFile(String savedFileId) async {
    return const QuarkPlayableFile(url: 'https://play.example.com/1.m3u8', headers: <String, String>{});
  }
}

class _MemoryHistoryRepository extends PlayHistoryRepository {
  final Map<String, PlayHistoryItem> map = <String, PlayHistoryItem>{};

  @override
  Future<PlayHistoryItem?> findByShareUrl(String shareUrl) async => map[shareUrl];

  @override
  Future<List<PlayHistoryItem>> listRecent({int limit = 50}) async {
    final list = map.values.toList();
    list.sort((a, b) => b.updatedAtEpochMs.compareTo(a.updatedAtEpochMs));
    return list;
  }

  @override
  Future<void> upsertByShareUrl(PlayHistoryItem item) async {
    map[item.shareUrl] = item;
  }
}

void main() {
  test('prepareEpisodes transfers when folder empty', () async {
    final transfer = _FakeTransferService();
    final history = _MemoryHistoryRepository();
    final orchestrator = SharePlayOrchestrator(
      authService: _FakeAuthService(),
      transferService: transfer,
      historyRepository: history,
    );

    final prepared = await orchestrator.prepareEpisodes(
      const SharePlayRequest(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/v/1',
        title: '测试剧',
      ),
    );

    expect(transfer.transferred, isTrue);
    expect(prepared.episodes.length, 2);
    expect(prepared.episodes.first.name, '第1集.mp4');
  });

  test('prepareEpisodes skips transfer when folder has videos', () async {
    final transfer = _FakeTransferService();
    transfer.files = <QuarkFileEntry>[
      const QuarkFileEntry(fileId: 'e1', fileName: '第1集.mp4', isDirectory: false),
    ];
    final history = _MemoryHistoryRepository();
    final orchestrator = SharePlayOrchestrator(
      authService: _FakeAuthService(),
      transferService: transfer,
      historyRepository: history,
    );

    final prepared = await orchestrator.prepareEpisodes(
      const SharePlayRequest(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/v/1',
        title: '测试剧',
      ),
    );

    expect(transfer.transferred, isFalse);
    expect(prepared.episodes.length, 1);
  });

  test('playEpisode updates history and returns media', () async {
    final transfer = _FakeTransferService();
    transfer.files = <QuarkFileEntry>[
      const QuarkFileEntry(fileId: 'e1', fileName: '第1集.mp4', isDirectory: false),
    ];
    final history = _MemoryHistoryRepository();
    final orchestrator = SharePlayOrchestrator(
      authService: _FakeAuthService(),
      transferService: transfer,
      historyRepository: history,
    );

    final prepared = await orchestrator.prepareEpisodes(
      const SharePlayRequest(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/v/1',
        title: '测试剧',
      ),
    );

    final media = await orchestrator.playEpisode(prepared, prepared.episodes.first);
    expect(media.url, 'https://play.example.com/1.m3u8');

    final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
    expect(saved?.lastEpisodeName, '第1集.mp4');
  });
}

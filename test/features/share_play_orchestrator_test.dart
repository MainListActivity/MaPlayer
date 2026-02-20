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

  bool savedSelected = false;
  bool clearedBeforeSave = false;
  bool clearedAfterSave = false;
  List<QuarkShareFileEntry> shareEpisodes = const <QuarkShareFileEntry>[
    QuarkShareFileEntry(
      fid: 's1',
      fileName: '第1集.mp4',
      pdirFid: '0',
      shareFidToken: 't1',
      isDirectory: false,
    ),
    QuarkShareFileEntry(
      fid: 's2',
      fileName: '第2集.mp4',
      pdirFid: '0',
      shareFidToken: 't2',
      isDirectory: false,
    ),
  ];
  List<QuarkFileEntry> files = <QuarkFileEntry>[
    const QuarkFileEntry(fileId: 'd2', fileName: '第2集.mp4', isDirectory: false),
    const QuarkFileEntry(fileId: 'd-x', fileName: '其他.mp4', isDirectory: false),
  ];

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
  Future<List<QuarkShareFileEntry>> listShareEpisodes(String shareUrl) async {
    return shareEpisodes;
  }

  @override
  Future<void> clearFolder(String folderId) async {
    clearedBeforeSave = true;
  }

  @override
  Future<void> clearFolderExcept(String folderId, String keepFileId) async {
    expect(keepFileId, 'd2');
    clearedAfterSave = true;
  }

  @override
  Future<void> saveShareEpisodeToFolder({
    required String shareUrl,
    required QuarkShareFileEntry episode,
    required String folderId,
  }) async {
    expect(episode.fid, 's2');
    savedSelected = true;
  }

  @override
  Future<List<QuarkFileEntry>> listFilesInFolder(String folderId) async {
    return files;
  }

  @override
  Future<QuarkPlayableFile> resolvePlayableFile(String savedFileId) async {
    expect(savedFileId, 'd2');
    return const QuarkPlayableFile(url: 'https://play.example.com/2.m3u8', headers: <String, String>{});
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
  test('prepareEpisodes checks auth and caches share episodes', () async {
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

    expect(prepared.episodes.length, 2);
    expect(prepared.episodes.first.name, '第1集.mp4');
    final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
    expect(saved?.cachedEpisodes.length, 2);
  });

  test('playEpisode skips transfer when selected episode already exists', () async {
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
    final selected = prepared.episodes[1];
    final media = await orchestrator.playEpisode(prepared, selected);

    expect(media.url, 'https://play.example.com/2.m3u8');
    expect(transfer.clearedBeforeSave, isFalse);
    expect(transfer.savedSelected, isFalse);
    expect(transfer.clearedAfterSave, isTrue);

    final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
    expect(saved?.lastEpisodeFileId, 's2');
    expect(saved?.lastEpisodeName, '第2集.mp4');
  });
}

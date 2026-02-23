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
      expiresAtEpochMs: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
  }
}

class _FakeTransferService extends QuarkTransferService {
  _FakeTransferService() : super(authService: _FakeAuthService());

  int findOrCreateCount = 0;
  bool savedSelected = false;
  bool clearedBeforeSave = false;
  bool clearedAfterSave = false;
  String? lastListedFolderId;
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
  Future<QuarkFolderLookupResult> findOrCreateShowFolder(
    String rootDir,
    String showDirName,
  ) async {
    findOrCreateCount += 1;
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
    lastListedFolderId = folderId;
    return files;
  }

  @override
  Future<QuarkPlayableFile> resolvePlayableFile(String savedFileId) async {
    expect(savedFileId, 'd2');
    return const QuarkPlayableFile(
      url: 'https://play.example.com/2.m3u8',
      headers: <String, String>{},
    );
  }
}

class _MemoryHistoryRepository extends PlayHistoryRepository {
  final Map<String, PlayHistoryItem> map = <String, PlayHistoryItem>{};

  @override
  Future<PlayHistoryItem?> findByShareUrl(String shareUrl) async =>
      map[shareUrl];

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
        year: '2024',
        rating: '8.9',
        category: '科幻',
        intro: '新简介',
      ),
    );

    expect(prepared.episodes.length, 2);
    expect(prepared.episodes.first.name, '第1集.mp4');
    final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
    expect(saved?.cachedEpisodes.length, 2);
    expect(saved?.showFolderId, isNull);
    expect(saved?.year, '2024');
    expect(saved?.rating, '8.9');
    expect(saved?.category, '科幻');
    expect(saved?.intro, '新简介');
  });

  test(
    'playEpisode transfers selected episode when no prior episode exists',
    () async {
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
      expect(transfer.clearedBeforeSave, isTrue);
      expect(transfer.savedSelected, isTrue);
      expect(transfer.clearedAfterSave, isTrue);
      expect(transfer.findOrCreateCount, 1);

      final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
      expect(saved?.lastEpisodeFileId, 's2');
      expect(saved?.lastEpisodeName, '第2集.mp4');
      expect(saved?.showFolderId, 'folder1');
    },
  );

  test(
    'playEpisode reuses recorded folder id before fallback to find/create',
    () async {
      final transfer = _FakeTransferService();
      final history = _MemoryHistoryRepository();
      history.map['https://pan.quark.cn/s/abc'] = const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/v/1',
        title: '测试剧',
        coverUrl: '',
        intro: '',
        showDirName: '测试剧',
        showFolderId: 'folder_cached',
        updatedAtEpochMs: 1,
        cachedEpisodes: <PlayHistoryEpisode>[
          PlayHistoryEpisode(
            fileId: 's1',
            name: '第1集.mp4',
            shareFidToken: 't1',
          ),
          PlayHistoryEpisode(
            fileId: 's2',
            name: '第2集.mp4',
            shareFidToken: 't2',
          ),
        ],
      );

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
      await orchestrator.playEpisode(prepared, selected);

      expect(prepared.preferredFolderId, 'folder_cached');
      expect(transfer.findOrCreateCount, 0);
      expect(transfer.lastListedFolderId, 'folder_cached');
    },
  );

  test(
    'prepareEpisodes keeps existing metadata when request is partial',
    () async {
      final transfer = _FakeTransferService();
      final history = _MemoryHistoryRepository();
      history.map['https://pan.quark.cn/s/abc'] = const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/voddetail/1.html',
        title: '旧标题',
        coverUrl:
            'https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2928387071.jpg',
        coverHeaders: <String, String>{'Referer': 'https://movie.douban.com/'},
        year: '2022',
        rating: '7.1',
        category: '悬疑',
        intro: '旧简介',
        showDirName: '旧标题',
        updatedAtEpochMs: 1,
      );

      final orchestrator = SharePlayOrchestrator(
        authService: _FakeAuthService(),
        transferService: transfer,
        historyRepository: history,
      );

      await orchestrator.prepareEpisodes(
        const SharePlayRequest(
          shareUrl: 'https://pan.quark.cn/s/abc',
          pageUrl: '',
          title: '',
        ),
      );

      final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
      expect(saved, isNotNull);
      expect(saved?.pageUrl, 'https://www.wogg.net/voddetail/1.html');
      expect(saved?.title, '旧标题');
      expect(saved?.coverUrl, contains('doubanio.com'));
      expect(saved?.year, '2022');
      expect(saved?.rating, '7.1');
      expect(saved?.category, '悬疑');
      expect(saved?.intro, '旧简介');
    },
  );

  test('prepareEpisodes normalizes baidu cover redirect and headers', () async {
    final transfer = _FakeTransferService();
    final history = _MemoryHistoryRepository();
    final orchestrator = SharePlayOrchestrator(
      authService: _FakeAuthService(),
      transferService: transfer,
      historyRepository: history,
    );

    await orchestrator.prepareEpisodes(
      const SharePlayRequest(
        shareUrl: 'https://pan.quark.cn/s/abc',
        pageUrl: 'https://www.wogg.net/voddetail/119576.html',
        title: '测试剧',
        year: '2020',
        rating: '8.2',
        category: '动作',
        coverUrl:
            'https://image.baidu.com/search/down?url=https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2928387071.jpg',
        coverHeaders: <String, String>{
          'Referer': 'https://www.wogg.net/voddetail/119576.html',
          'Origin': 'https://www.wogg.net',
        },
      ),
    );

    final saved = await history.findByShareUrl('https://pan.quark.cn/s/abc');
    expect(saved, isNotNull);
    expect(
      saved?.coverUrl,
      'https://image.baidu.com/search/down?url=https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2928387071.jpg',
    );
    expect(saved?.coverHeaders, isEmpty);
    expect(saved?.year, '2020');
    expect(saved?.rating, '8.2');
    expect(saved?.category, '动作');
  });

  test(
    'prepareEpisodes uses share id as show dir when title is placeholder',
    () async {
      final transfer = _FakeTransferService();
      final history = _MemoryHistoryRepository();
      final orchestrator = SharePlayOrchestrator(
        authService: _FakeAuthService(),
        transferService: transfer,
        historyRepository: history,
      );

      final prepared = await orchestrator.prepareEpisodes(
        const SharePlayRequest(
          shareUrl: 'https://pan.quark.cn/s/abc123',
          pageUrl: 'https://www.wogg.net/v/1',
          title: '未命名剧集',
        ),
      );

      expect(prepared.showDirName, 'abc123');
    },
  );
}

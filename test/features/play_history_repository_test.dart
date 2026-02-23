import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('upsert and list recent by share url', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repo = PlayHistoryRepository();

    await repo.upsertByShareUrl(
      const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/a',
        pageUrl: 'https://www.wogg.net/x',
        title: 'A',
        coverUrl: '',
        coverHeaders: <String, String>{'Referer': 'https://www.wogg.net/x'},
        year: '2021',
        rating: '7.9',
        category: '剧情',
        intro: '',
        showDirName: 'A',
        updatedAtEpochMs: 1,
      ),
    );

    await repo.upsertByShareUrl(
      const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/a',
        pageUrl: 'https://www.wogg.net/v/1',
        title: 'A-2',
        coverUrl: 'https://img.wogg.net/new-cover.jpg',
        coverHeaders: <String, String>{'Referer': 'https://www.wogg.net/v/1'},
        year: '2023',
        rating: '8.3',
        category: '科幻',
        intro: '',
        showDirName: 'A',
        updatedAtEpochMs: 2,
        lastEpisodeFileId: 'f1',
        lastEpisodeName: '第1集',
      ),
    );

    await repo.upsertByShareUrl(
      const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/b',
        pageUrl: 'https://www.wogg.net/y',
        title: 'B',
        coverUrl: '',
        intro: '',
        showDirName: 'B',
        updatedAtEpochMs: 3,
      ),
    );

    final list = await repo.listRecent();
    expect(list.length, 2);
    expect(list.first.shareUrl, 'https://pan.quark.cn/s/b');

    final a = await repo.findByShareUrl('https://pan.quark.cn/s/a');
    expect(a?.title, 'A-2');
    expect(a?.pageUrl, 'https://www.wogg.net/v/1');
    expect(a?.coverUrl, 'https://img.wogg.net/new-cover.jpg');
    expect(a?.lastEpisodeFileId, 'f1');
    expect(a?.coverHeaders['Referer'], 'https://www.wogg.net/v/1');
    expect(a?.year, '2023');
    expect(a?.rating, '8.3');
    expect(a?.category, '科幻');
  });

  test('migrates bare doubanio.com cover URLs to Baidu proxy on load', () async {
    const doubanUrl =
        'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p123.webp';
    const expectedUrl =
        'https://image.baidu.com/search/down?url=https%3A%2F%2Fimg9.doubanio.com%2Fview%2Fphoto%2Fs_ratio_poster%2Fpublic%2Fp123.webp';

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final repo = PlayHistoryRepository();

    await repo.upsertByShareUrl(
      const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/c',
        pageUrl: 'https://example.com/movie',
        title: 'Movie',
        coverUrl: doubanUrl,
        year: '2024',
        rating: '8.1',
        category: '悬疑',
        intro: '',
        showDirName: 'Movie',
        updatedAtEpochMs: 1,
      ),
    );

    // Simulate a legacy entry by writing the raw douban URL directly to prefs
    // (already done via upsert above since migration only runs on load).
    // Now read back — migration should have converted the URL on first load.
    final item = await repo.findByShareUrl('https://pan.quark.cn/s/c');
    expect(item?.coverUrl, expectedUrl);

    // Second load should return same value (idempotent).
    final item2 = await repo.findByShareUrl('https://pan.quark.cn/s/c');
    expect(item2?.coverUrl, expectedUrl);
    expect(item2?.year, '2024');
    expect(item2?.rating, '8.1');
    expect(item2?.category, '悬疑');
  });

  test('backward compatible when metadata fields are missing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'play_history_v1': '''
[
  {
    "shareUrl":"https://pan.quark.cn/s/legacy",
    "pageUrl":"https://example.com/legacy",
    "title":"Legacy",
    "coverUrl":"",
    "intro":"",
    "showDirName":"Legacy",
    "updatedAtEpochMs":1
  }
]
''',
    });

    final repo = PlayHistoryRepository();
    final item = await repo.findByShareUrl('https://pan.quark.cn/s/legacy');
    expect(item, isNotNull);
    expect(item?.year, '');
    expect(item?.rating, '');
    expect(item?.category, '');
  });
}

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
        intro: '',
        showDirName: 'A',
        updatedAtEpochMs: 1,
      ),
    );

    await repo.upsertByShareUrl(
      const PlayHistoryItem(
        shareUrl: 'https://pan.quark.cn/s/a',
        pageUrl: 'https://www.wogg.net/x',
        title: 'A-2',
        coverUrl: '',
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
    expect(a?.lastEpisodeFileId, 'f1');
  });
}

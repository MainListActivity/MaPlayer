import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/history/history_cover_utils.dart';

void main() {
  group('normalizeHistoryCover', () {
    test('wraps doubanio.com URL with Baidu proxy', () {
      const doubanUrl =
          'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2926587194.webp';
      final result = normalizeHistoryCover(coverUrl: doubanUrl);

      expect(
        result.coverUrl,
        'https://image.baidu.com/search/down?url=https%3A%2F%2Fimg9.doubanio.com%2Fview%2Fphoto%2Fs_ratio_poster%2Fpublic%2Fp2926587194.webp',
      );
      expect(result.coverHeaders, isEmpty);
    });

    test('preserves existing Baidu proxy URL unchanged', () {
      const proxyUrl =
          'https://image.baidu.com/search/down?url=https%3A%2F%2Fimg9.doubanio.com%2Fview%2Fphoto%2Fs_ratio_poster%2Fpublic%2Fp2926587194.webp';
      final result = normalizeHistoryCover(
        coverUrl: proxyUrl,
        coverHeaders: {'Referer': 'https://image.baidu.com'},
      );

      expect(result.coverUrl, proxyUrl);
    });

    test('returns empty for empty input', () {
      final result = normalizeHistoryCover(coverUrl: '');
      expect(result.coverUrl, isEmpty);
      expect(result.coverHeaders, isEmpty);
    });

    test('strips headers when Referer host does not match cover host', () {
      const url = 'https://img.example.com/cover.jpg';
      final result = normalizeHistoryCover(
        coverUrl: url,
        coverHeaders: {'Referer': 'https://other.com'},
      );
      expect(result.coverHeaders, isEmpty);
    });

    test('keeps headers when Referer host matches cover host', () {
      const url = 'https://img.wogg.net/cover.jpg';
      final result = normalizeHistoryCover(
        coverUrl: url,
        coverHeaders: {'Referer': 'https://img.wogg.net/some/page'},
      );
      expect(result.coverHeaders['Referer'], 'https://img.wogg.net/some/page');
    });
  });
}

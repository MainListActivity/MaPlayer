import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';

void main() {
  group('TvBoxConfigRepository.normalizeSubscriptionUrl', () {
    final repository = TvBoxConfigRepository();

    test('keeps valid punycode url', () {
      const input = 'http://tvbox.xn--4kq62z5rby2qupq9ub.top/';
      final normalized = repository.normalizeSubscriptionUrl(input);
      expect(normalized, input);
    });

    test('adds http scheme when missing', () {
      const input = 'example.com/tvbox.json';
      final normalized = repository.normalizeSubscriptionUrl(input);
      expect(normalized, 'http://example.com/tvbox.json');
    });

    test('normalizes full-width separators', () {
      const input = 'http：／／example.com/a.json';
      final normalized = repository.normalizeSubscriptionUrl(input);
      expect(normalized, 'http://example.com/a.json');
    });

    test('throws when host is missing', () {
      expect(
        () => repository.normalizeSubscriptionUrl('https:///abc'),
        throwsFormatException,
      );
    });
  });
}

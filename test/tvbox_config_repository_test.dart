import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('TvBoxConfigRepository.normalizeOptionalHttpUrl', () {
    final repository = TvBoxConfigRepository();

    test('returns null for null or empty input', () {
      expect(repository.normalizeOptionalHttpUrl(null), isNull);
      expect(repository.normalizeOptionalHttpUrl('   '), isNull);
    });

    test('normalizes url when value is present', () {
      expect(
        repository.normalizeOptionalHttpUrl('example.com/bridge.js'),
        'http://example.com/bridge.js',
      );
    });

    test('throws for unsupported scheme', () {
      expect(
        () => repository.normalizeOptionalHttpUrl('ftp://example.com/a.js'),
        throwsFormatException,
      );
    });
  });

  group('TvBoxConfigRepository remote bridge js url', () {
    test('save/load/clear and revision update', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repository = TvBoxConfigRepository();
      final startRevision = TvBoxConfigRepository.configRevision.value;

      await repository.saveHomeBridgeRemoteJsUrl('https://a.example/bridge.js');
      expect(
        await repository.loadHomeBridgeRemoteJsUrlOrNull(),
        'https://a.example/bridge.js',
      );
      expect(TvBoxConfigRepository.configRevision.value, startRevision + 1);

      await repository.saveHomeBridgeRemoteJsUrl('https://a.example/bridge.js');
      expect(TvBoxConfigRepository.configRevision.value, startRevision + 1);

      await repository.saveHomeBridgeRemoteJsUrl('');
      expect(await repository.loadHomeBridgeRemoteJsUrlOrNull(), isNull);
      expect(TvBoxConfigRepository.configRevision.value, startRevision + 2);
    });

    test('invalid persisted value falls back to null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'home_bridge_remote_js_url': 'ftp://bad.example/bridge.js',
      });
      final repository = TvBoxConfigRepository();
      expect(await repository.loadHomeBridgeRemoteJsUrlOrNull(), isNull);
    });
  });
}

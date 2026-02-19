import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/tvbox/tvbox_parser.dart';
import 'package:ma_palyer/tvbox/tvbox_source_resolver.dart';

class FakeTvBoxSourceResolver implements TvBoxSourceResolver {
  FakeTvBoxSourceResolver(this.store);

  final Map<String, String> store;

  @override
  Future<String> load(Uri uri, {required Duration timeout}) async {
    final key = uri.toString();
    if (!store.containsKey(key)) {
      throw Exception('404 $key');
    }
    return store[key]!;
  }
}

void main() {
  test('valid_full_config', () async {
    final parser = TvBoxParser();
    const raw = '''
{
  "spider": "./jar/spider.jar",
  "sites": [{"key": "csp_xx", "name": "示例站点", "type": 3, "api": "csp_XPath", "quickSearch": "1"}],
  "lives": [{"name": "直播", "url": "https://example.com/live.txt", "header": {"ua": "test"}}],
  "parses": [{"name": "线路1", "url": "https://parse.example.com", "web": "1", "priority": "2"}],
  "drives": [{"provider": "aliyun", "name": "阿里云盘", "api": "https://drive.example.com"}],
  "rules": [{"enable": "1", "match": "a", "replace": "b", "priority": "3"}],
  "player": {"ua": "UA", "timeout": "10", "retry": "2"},
  "flags": ["youku", "qq"]
}
''';

    final report = await parser.parseString(raw);

    expect(report.hasFatalError, isFalse);
    expect(report.config, isNotNull);
    expect(report.config!.sites.length, 1);
    expect(report.config!.lives.length, 1);
    expect(report.config!.parses.length, 1);
    expect(report.config!.drives.length, 1);
    expect(report.config!.rules.length, 1);
    expect(report.config!.player?.timeout, 10);
    expect(report.config!.parses.first.web, isTrue);
  });

  test('tolerant_type_and_unknown_preserve', () async {
    final parser = TvBoxParser();
    const raw = '''
{
  "sites": [{"key": "k", "name": "n", "searchable": "1", "x-extra": 1}],
  "parses": "bad-type",
  "foo": {"bar": 1}
}
''';

    final report = await parser.parseString(raw);
    expect(report.hasFatalError, isFalse);
    expect(report.warningCount, greaterThan(0));
    expect(report.config!.extras.containsKey('foo'), isTrue);
    expect(report.config!.sites.first.extras.containsKey('x-extra'), isTrue);
  });

  test('drop_invalid_site_when_key_and_name_missing', () async {
    final parser = TvBoxParser();
    const raw = '''
{
  "sites": [{"api": "a"}, {"key": "ok"}]
}
''';

    final report = await parser.parseString(raw);
    expect(report.config!.sites.length, 1);
    expect(
      report.issues.any((e) => e.code == 'TVB_REQUIRED_SITE_KEY_OR_NAME'),
      isTrue,
    );
  });

  test('ext_single_layer_and_local_override', () async {
    final resolver = FakeTvBoxSourceResolver({
      'https://example.com/ext.json':
          '{"sites": [{"key": "remote", "name": "r"}], "ua": "remote"}',
    });
    final parser = TvBoxParser(sourceResolver: resolver);
    const raw =
        '{"ext": "https://example.com/ext.json", "ua": "local", "sites": [{"key": "local", "name": "l"}]}';

    final report = await parser.parseString(raw);
    expect(report.hasFatalError, isFalse);
    expect(report.config!.ua, 'local');
    expect(report.config!.sites.first.key, 'local');
    expect(report.config!.resolvedExtRaw, isNotNull);
  });

  test('ext_recursive_relative_and_cycle', () async {
    final resolver = FakeTvBoxSourceResolver({
      'https://example.com/a.json':
          '{"ext": "b.json", "sites": [{"key": "a", "name": "A"}]}',
      'https://example.com/b.json': '{"ext": "a.json", "ua": "B"}',
    });
    final parser = TvBoxParser(sourceResolver: resolver, maxDepth: 8);
    const raw = '{"ext": "https://example.com/a.json"}';

    final report = await parser.parseString(raw);
    expect(report.hasFatalError, isFalse);
    expect(report.errorCount, greaterThan(0));
    expect(report.issues.any((e) => e.code == 'TVB_EXT_CYCLE'), isTrue);
    expect(report.config, isNotNull);
  });

  test('ext_non_json_and_404_should_record_issue', () async {
    final resolver = FakeTvBoxSourceResolver({
      'https://example.com/nonjson': '[1,2,3]',
    });
    final parser = TvBoxParser(sourceResolver: resolver);

    final report1 = await parser.parseString(
      '{"ext": "https://example.com/nonjson"}',
    );
    final report2 = await parser.parseString(
      '{"ext": "https://example.com/notfound"}',
    );

    expect(report1.issues.any((e) => e.code == 'TVB_EXT_NON_OBJECT'), isTrue);
    expect(report2.issues.any((e) => e.code == 'TVB_EXT_LOAD_FAILED'), isTrue);
  });

  test('parse_string_or_throw_only_on_fatal', () async {
    final parser = TvBoxParser();

    await expectLater(
      () => parser.parseStringOrThrow('{"sites": []}'),
      returnsNormally,
    );

    await expectLater(
      () => parser.parseStringOrThrow('[1,2,3]'),
      throwsA(isA<FormatException>()),
    );
  });
}

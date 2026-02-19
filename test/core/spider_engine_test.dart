import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';

TvBoxSite _site(String api) {
  return TvBoxSite(
    raw: const <String, dynamic>{},
    extras: const <String, dynamic>{},
    key: 'k',
    name: 'n',
    api: api,
  );
}

TvBoxSite _siteWithJar(String api, String jar) {
  return TvBoxSite(
    raw: const <String, dynamic>{},
    extras: const <String, dynamic>{},
    key: 'k',
    name: 'n',
    api: api,
    jar: jar,
  );
}

void main() {
  test('detectEngineFromSite detects js', () {
    expect(
      detectEngineFromSite(_site('https://x/test.js')),
      SpiderEngineType.js,
    );
  });

  test('detectEngineFromSite detects py', () {
    expect(
      detectEngineFromSite(_site('https://x/test.py')),
      SpiderEngineType.py,
    );
  });

  test('detectEngineFromSite defaults to jar', () {
    expect(detectEngineFromSite(_site('csp_XPath')), SpiderEngineType.jar);
  });

  test('detectEngineFromSite detects js from jar', () {
    expect(
      detectEngineFromSite(_siteWithJar('csp_XPath', 'https://x/spider.js')),
      SpiderEngineType.js,
    );
  });

  test('detectEngineFromSite detects py from global spider', () {
    expect(
      detectEngineFromSite(
        _site('csp_XPath'),
        globalSpider: 'https://x/spider.py',
      ),
      SpiderEngineType.py,
    );
  });
}

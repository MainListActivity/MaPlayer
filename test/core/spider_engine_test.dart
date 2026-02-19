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
}

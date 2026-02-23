import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/playback/play_detail_payload_parser.dart';

void main() {
  test('parses canonical detail keys', () {
    final parsed = parsePlayDetailPayload(<String, dynamic>{
      'year': '2024',
      'rating': '8.8',
      'category': '科幻',
      'intro': '这是简介',
    });

    expect(parsed.year, '2024');
    expect(parsed.rating, '8.8');
    expect(parsed.category, '科幻');
    expect(parsed.intro, '这是简介');
  });

  test('parses vod aliases and normalizes year/rating/category list', () {
    final parsed = parsePlayDetailPayload(<String, dynamic>{
      'vod_year': '年份：2023',
      'vod_score': '豆瓣 7.6',
      'type_name': <String>['剧情', '悬疑'],
      'vod_content': '   剧情简介   ',
    });

    expect(parsed.year, '2023');
    expect(parsed.rating, '7.6');
    expect(parsed.category, '剧情 / 悬疑');
    expect(parsed.intro, '剧情简介');
  });

  test('returns null fields when payload values are empty', () {
    final parsed = parsePlayDetailPayload(<String, dynamic>{
      'year': ' ',
      'score': '',
      'genres': <String>[],
      'desc': null,
    });

    expect(parsed.year, isNull);
    expect(parsed.rating, isNull);
    expect(parsed.category, isNull);
    expect(parsed.intro, isNull);
  });
}

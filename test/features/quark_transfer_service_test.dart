import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_transfer_service.dart';

class _FakeAuthService extends QuarkAuthService {
  _FakeAuthService(this.state);

  final QuarkAuthState state;

  @override
  Future<QuarkAuthState> ensureValidToken() async => state;
}

String? _headerValue(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value;
    }
  }
  return null;
}

String? _cookieValue(String? cookieHeader, String name) {
  if (cookieHeader == null) return null;
  for (final segment in cookieHeader.split(';')) {
    final trimmed = segment.trim();
    if (!trimmed.contains('=')) continue;
    final idx = trimmed.indexOf('=');
    if (trimmed.substring(0, idx).trim() != name) continue;
    return trimmed.substring(idx + 1).trim();
  }
  return null;
}

void main() {
  test(
    'resolvePlayableFile includes auth Cookie and User-Agent in playback headers',
    () async {
      const cookie = 'sid=abc; kps=xyz';
      final authService = _FakeAuthService(
        QuarkAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAtEpochMs: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          cookie: cookie,
        ),
      );

      final client = MockClient((http.Request request) async {
        expect(request.url.path, '/1/clouddrive/file/v2/play');
        expect(_headerValue(request.headers, 'Cookie'), cookie);
        expect(_headerValue(request.headers, 'User-Agent'), isNotEmpty);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'code': 0,
            'data': <String, dynamic>{
              'video_list': <Map<String, dynamic>>[
                <String, dynamic>{
                  'resolution': 'high',
                  'video_info': <String, dynamic>{
                    'url': 'https://video.example.com/high.m3u8',
                    'headers': <String, String>{
                      'Referer': 'https://pan.quark.cn/',
                      'user-agent': 'bad-ua',
                      'Cookie': 'bad-cookie=1',
                    },
                  },
                },
              ],
            },
          }),
          200,
        );
      });

      final service = QuarkTransferService(
        authService: authService,
        httpClient: client,
        baseUri: Uri.parse('https://drive-pc.quark.cn/1/clouddrive/'),
      );

      final playable = await service.resolvePlayableFile('file-1');
      expect(playable.url, 'https://video.example.com/high.m3u8');
      expect(playable.headers['Referer'], 'https://pan.quark.cn/');
      expect(playable.headers['Cookie'], cookie);
      expect(playable.headers['User-Agent'], isNotEmpty);
      expect(playable.headers.containsKey('user-agent'), isFalse);
    },
  );

  test('resolvePlayableFile uses latest Video-Auth from set-cookie', () async {
    const cookie = 'sid=abc; Video-Auth=old-auth';
    final authService = _FakeAuthService(
      QuarkAuthState(
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAtEpochMs: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        cookie: cookie,
      ),
    );

    final client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'video_list': <Map<String, dynamic>>[
              <String, dynamic>{
                'resolution': 'high',
                'video_info': <String, dynamic>{
                  'url': 'https://video.example.com/high.m3u8',
                },
              },
            ],
          },
        }),
        200,
        headers: <String, String>{
          'set-cookie':
              'Video-Auth=new-auth; Max-Age=3600; Expires=Fri, 20-Feb-2026 14:27:19 GMT; Domain=quark.cn; Path=/',
        },
      );
    });

    final service = QuarkTransferService(
      authService: authService,
      httpClient: client,
      baseUri: Uri.parse('https://drive-pc.quark.cn/1/clouddrive/'),
    );

    final playable = await service.resolvePlayableFile('file-1');
    final playbackCookie = playable.headers['Cookie'];
    expect(_cookieValue(playbackCookie, 'sid'), 'abc');
    expect(_cookieValue(playbackCookie, 'Video-Auth'), 'new-auth');
    expect(playbackCookie, isNot(contains('old-auth')));
  });

  test(
    'findOrCreateShowFolder handles mkdir 400 conflict by reusing existing folder',
    () async {
      final authService = _FakeAuthService(
        QuarkAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAtEpochMs: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          cookie: 'sid=abc',
        ),
      );

      var rootListCount = 0;
      final client = MockClient((http.Request request) async {
        if (request.url.path == '/1/clouddrive/file/sort') {
          final pdir = request.url.queryParameters['pdir_fid'] ?? '';
          if (pdir == '0') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'list': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'fid': 'root-folder-id',
                      'file_name': 'MaPlayer',
                      'dir': true,
                    },
                  ],
                },
              }),
              200,
            );
          }
          if (pdir == 'root-folder-id') {
            rootListCount += 1;
            final hasShowFolder = rootListCount >= 2;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'list': hasShowFolder
                      ? <Map<String, dynamic>>[
                          <String, dynamic>{
                            'fid': 'show-folder-id',
                            'file_name': 'ShowName',
                            'dir': true,
                          },
                        ]
                      : <Map<String, dynamic>>[],
                },
              }),
              200,
            );
          }
        }

        if (request.url.path == '/1/clouddrive/file' &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'status': 400,
              'code': 23008,
              'message': 'file is doloading[name conflict]',
            }),
            400,
          );
        }

        return http.Response('not found', 404);
      });

      final service = QuarkTransferService(
        authService: authService,
        httpClient: client,
        baseUri: Uri.parse('https://pan.quark.cn/1/clouddrive/'),
      );

      final result = await service.findOrCreateShowFolder(
        '/MaPlayer',
        'ShowName',
      );
      expect(result.folderId, 'show-folder-id');
      expect(result.folderName, 'ShowName');
    },
  );

  test(
    'listShareEpisodes requests _fetch_share=1 and keeps share_fid_token',
    () async {
      final authService = _FakeAuthService(
        QuarkAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAtEpochMs: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          cookie: 'sid=abc',
        ),
      );

      var detailRequestCount = 0;
      final detailFetchShareValues = <String?>[];

      final client = MockClient((http.Request request) async {
        if (request.url.path == '/1/clouddrive/share/sharepage/token') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{'stoken': 'stoken-1'},
            }),
            200,
          );
        }

        if (request.url.path == '/1/clouddrive/share/sharepage/detail') {
          detailRequestCount += 1;
          detailFetchShareValues.add(
            request.url.queryParameters['_fetch_share'],
          );
          return http.Response(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{
                'list': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'fid': 'f2',
                    'file_name': 'ep2.mp4',
                    'pdir_fid': '0',
                    'share_fid_token': 'token-2',
                    'dir': false,
                  },
                ],
              },
            }),
            200,
          );
        }

        return http.Response('not found', 404);
      });

      final service = QuarkTransferService(
        authService: authService,
        httpClient: client,
        baseUri: Uri.parse('https://drive-pc.quark.cn/1/clouddrive/'),
      );

      final episodes = await service.listShareEpisodes(
        'https://pan.quark.cn/s/abc',
      );

      expect(episodes.length, 1);
      expect(episodes.first.fid, 'f2');
      expect(episodes.first.shareFidToken, 'token-2');

      expect(detailRequestCount, greaterThan(0));
      expect(detailFetchShareValues, isNotEmpty);
      expect(
        detailFetchShareValues.every((v) => v == '1'),
        isTrue,
        reason:
            'share detail must request share token fields for subsequent save',
      );
    },
  );

  test(
    'findOrCreateShowFolder falls back to non-empty folder name when input is blank',
    () async {
      final authService = _FakeAuthService(
        QuarkAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAtEpochMs: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          cookie: 'sid=abc',
        ),
      );

      String? createdName;
      var rootListCount = 0;

      final client = MockClient((http.Request request) async {
        if (request.url.path == '/1/clouddrive/file/sort') {
          final pdir = request.url.queryParameters['pdir_fid'] ?? '';
          if (pdir == '0') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'list': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'fid': 'root-folder-id',
                      'file_name': 'MaPlayer',
                      'dir': true,
                    },
                  ],
                },
              }),
              200,
            );
          }
          if (pdir == 'root-folder-id') {
            rootListCount += 1;
            if (rootListCount == 1) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'code': 0,
                  'data': <String, dynamic>{'list': <Map<String, dynamic>>[]},
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode(<String, dynamic>{
                'code': 0,
                'data': <String, dynamic>{
                  'list': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'fid': 'show-folder-id',
                      'file_name': createdName ?? '',
                      'dir': true,
                    },
                  ],
                },
              }),
              200,
            );
          }
        }

        if (request.url.path == '/1/clouddrive/file' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          createdName = body['file_name']?.toString();
          return http.Response(
            jsonEncode(<String, dynamic>{
              'code': 0,
              'data': <String, dynamic>{},
            }),
            200,
          );
        }

        return http.Response('not found', 404);
      });

      final service = QuarkTransferService(
        authService: authService,
        httpClient: client,
        baseUri: Uri.parse('https://pan.quark.cn/1/clouddrive/'),
      );

      final result = await service.findOrCreateShowFolder('/MaPlayer', '   ');
      expect(createdName, 'untitled_show');
      expect(result.folderName, 'untitled_show');
    },
  );
}

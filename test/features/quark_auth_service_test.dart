import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ma_palyer/core/security/credential_store.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';

class _MemoryCredentialStore extends CredentialStore {
  _MemoryCredentialStore();

  final Map<String, Map<String, dynamic>> _store =
      <String, Map<String, dynamic>>{};

  @override
  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    _store[key] = value;
  }

  @override
  Future<Map<String, dynamic>?> readJson(String key) async {
    return _store[key];
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}

void main() {
  test('ensureValidToken refreshes expired token', () async {
    final store = _MemoryCredentialStore();
    await store.writeJson(
      CredentialStore.quarkAuthKey,
      QuarkAuthState(
        accessToken: 'old-a',
        refreshToken: 'old-r',
        expiresAtEpochMs: DateTime.now()
            .subtract(const Duration(seconds: 3))
            .millisecondsSinceEpoch,
      ).toJson(),
    );

    final client = MockClient((http.Request request) async {
      expect(request.url.path, '/1/clouddrive/token/refresh');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{
            'accessToken': 'new-a',
            'refreshToken': 'new-r',
            'expiresIn': 3600,
          },
        }),
        200,
      );
    });

    final service = QuarkAuthService(
      credentialStore: store,
      httpClient: client,
      baseUri: Uri.parse('https://drive.quark.cn/1/clouddrive/'),
    );

    final state = await service.ensureValidToken();
    expect(state.accessToken, 'new-a');
    final saved = await store.readJson(CredentialStore.quarkAuthKey);
    expect(saved?['accessToken'], 'new-a');
  });

  test('ensureValidToken throws when no auth state', () async {
    final service = QuarkAuthService(
      credentialStore: _MemoryCredentialStore(),
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );

    expect(
      () => service.ensureValidToken(),
      throwsA(
        predicate((e) => e is QuarkException && e.code == 'AUTH_REQUIRED'),
      ),
    );
  });

  test('updateCookie persists latest cookie', () async {
    final store = _MemoryCredentialStore();
    final service = QuarkAuthService(
      credentialStore: store,
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );
    final current = QuarkAuthState(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAtEpochMs: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      cookie: 'sid=abc; __puus=old',
    );

    final next = await service.updateCookie(current, 'sid=abc; __puus=new');

    expect(next.cookie, 'sid=abc; __puus=new');
    final saved = await store.readJson(CredentialStore.quarkAuthKey);
    expect(saved?['cookie'], 'sid=abc; __puus=new');
  });
}

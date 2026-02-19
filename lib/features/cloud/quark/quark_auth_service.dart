import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ma_palyer/core/security/credential_store.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';

class QuarkAuthService {
  QuarkAuthService({
    CredentialStore? credentialStore,
    http.Client? httpClient,
    Uri? baseUri,
  }) : _credentialStore = credentialStore ?? CredentialStore(),
       _http = httpClient ?? http.Client(),
       _baseUri = baseUri ?? Uri.parse('https://drive.quark.cn/1/clouddrive/');

  final CredentialStore _credentialStore;
  final http.Client _http;
  final Uri _baseUri;

  Future<QuarkAuthState?> currentAuthState() async {
    final json = await _credentialStore.readJson(CredentialStore.quarkAuthKey);
    if (json == null) return null;
    final state = QuarkAuthState.fromJson(json);
    if (state.accessToken.isEmpty || state.refreshToken.isEmpty) {
      return null;
    }
    return state;
  }

  Future<void> clearAuthState() {
    return _credentialStore.delete(CredentialStore.quarkAuthKey);
  }

  Future<QuarkQrSession> createQrSession() async {
    final uri = _baseUri.resolve('login/qr/create');
    final response = await _http.post(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException(
        'Failed to create QR session',
        code: 'QR_CREATE_FAILED',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final sessionId = data['sessionId']?.toString() ?? '';
    final qrCodeUrl = data['qrCodeUrl']?.toString() ?? '';
    final expiresInSec = (data['expiresIn'] as num?)?.toInt() ?? 180;
    if (sessionId.isEmpty || qrCodeUrl.isEmpty) {
      throw QuarkException(
        'Invalid QR session payload',
        code: 'QR_CREATE_PAYLOAD',
      );
    }
    return QuarkQrSession(
      sessionId: sessionId,
      qrCodeUrl: qrCodeUrl,
      expiresAt: DateTime.now().add(Duration(seconds: expiresInSec)),
    );
  }

  Future<QuarkQrPollResult> pollQrLogin(String sessionId) async {
    final uri = _baseUri.resolve('login/qr/poll?session_id=$sessionId');
    final response = await _http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('Failed to poll QR login', code: 'QR_POLL_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final status = data['status']?.toString() ?? 'pending';
    if (status != 'confirmed') {
      return QuarkQrPollResult(status: status);
    }

    final token = data['accessToken']?.toString() ?? '';
    final refresh = data['refreshToken']?.toString() ?? '';
    final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 7200;
    final cookie = data['cookie']?.toString();
    if (token.isEmpty || refresh.isEmpty) {
      throw QuarkException('Invalid token payload', code: 'QR_POLL_PAYLOAD');
    }

    final state = QuarkAuthState(
      accessToken: token,
      refreshToken: refresh,
      expiresAtEpochMs:
          DateTime.now().millisecondsSinceEpoch + (expiresIn * 1000),
      cookie: cookie,
    );
    await _credentialStore.writeJson(
      CredentialStore.quarkAuthKey,
      state.toJson(),
    );
    return QuarkQrPollResult(status: status, authState: state);
  }

  Future<QuarkAuthState> ensureValidToken() async {
    final state = await currentAuthState();
    if (state == null) {
      throw QuarkException('Quark login required', code: 'AUTH_REQUIRED');
    }
    if (!state.isExpired) {
      return state;
    }

    final uri = _baseUri.resolve('token/refresh');
    final response = await _http.post(
      uri,
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'refreshToken': state.refreshToken}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException(
        'Token refresh failed',
        code: 'TOKEN_REFRESH_FAILED',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final next = QuarkAuthState(
      accessToken: data['accessToken']?.toString() ?? state.accessToken,
      refreshToken: data['refreshToken']?.toString() ?? state.refreshToken,
      expiresAtEpochMs:
          DateTime.now().millisecondsSinceEpoch +
          (((data['expiresIn'] as num?)?.toInt() ?? 7200) * 1000),
      cookie: data['cookie']?.toString() ?? state.cookie,
    );

    await _credentialStore.writeJson(
      CredentialStore.quarkAuthKey,
      next.toJson(),
    );
    return next;
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  void _logAuth(String message) {
    debugPrint('[QuarkAuth] $message');
  }

  Future<QuarkAuthState?> currentAuthState() async {
    final json = await _credentialStore.readJson(CredentialStore.quarkAuthKey);
    if (json == null) return null;
    final state = QuarkAuthState.fromJson(json);
    final hasTokenPair =
        state.accessToken.isNotEmpty && state.refreshToken.isNotEmpty;
    final hasCookie = state.cookie != null && state.cookie!.isNotEmpty;
    if (!hasTokenPair && !hasCookie) {
      return null;
    }
    return state;
  }

  Future<void> clearAuthState() {
    return _credentialStore.delete(CredentialStore.quarkAuthKey);
  }

  Future<QuarkAuthState?> syncAuthStateFromCookies(String cookieHeader) async {
    if (cookieHeader.trim().isEmpty) return null;
    final isLoggedIn = await probeLoginByCookie(cookieHeader);
    if (!isLoggedIn) {
      final allowFallback = _looksLikeAuthenticatedCookie(cookieHeader);
      if (!allowFallback) {
        return null;
      }
      _logAuth(
        'probe failed but cookie heuristic matched, accepting cookie login',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final state = QuarkAuthState(
      accessToken: '',
      refreshToken: '',
      expiresAtEpochMs: now + const Duration(days: 30).inMilliseconds,
      cookie: cookieHeader,
    );
    await _credentialStore.writeJson(
      CredentialStore.quarkAuthKey,
      state.toJson(),
    );
    return state;
  }

  Future<bool> probeLoginByCookie(String cookieHeader) async {
    final uri = _baseUri.resolve('user/info');
    final response = await _http.get(
      uri,
      headers: <String, String>{
        'Cookie': cookieHeader,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
        'Origin': 'https://pan.quark.cn',
        'Referer': 'https://pan.quark.cn/',
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/145.0.0.0 Safari/537.36',
      },
    );
    _logAuth('probe status=${response.statusCode}, body=${response.body}');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return false;
    }
    final body = jsonDecode(response.body);
    if (body is Map<String, dynamic>) {
      final success = body['success'];
      if (success is bool) return success;
      final code = body['code'];
      if (code is num) return code.toInt() == 0;
    }
    return true;
  }

  bool _looksLikeAuthenticatedCookie(String cookieHeader) {
    final cookieNames = cookieHeader
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.contains('='))
        .map((part) => part.substring(0, part.indexOf('=')))
        .map((name) => name.toLowerCase())
        .toSet();
    _logAuth('cookieNames: $cookieNames');
    // Must have all three required Quark auth cookies simultaneously.
    const requiredMarkers = ['__pus', '__puus'];
    return requiredMarkers.every((marker) => cookieNames.contains(marker));
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
    if (state.cookie != null &&
        state.cookie!.isNotEmpty &&
        state.refreshToken.isEmpty) {
      return state;
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

  Future<QuarkAuthState> updateCookie(
    QuarkAuthState current,
    String cookieHeader,
  ) async {
    final normalized = cookieHeader.trim();
    if (normalized.isEmpty || normalized == (current.cookie ?? '').trim()) {
      return current;
    }
    final next = QuarkAuthState(
      accessToken: current.accessToken,
      refreshToken: current.refreshToken,
      expiresAtEpochMs: current.expiresAtEpochMs,
      cookie: normalized,
    );
    await _credentialStore.writeJson(
      CredentialStore.quarkAuthKey,
      next.toJson(),
    );
    return next;
  }
}

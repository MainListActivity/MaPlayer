import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String quarkAuthKey = 'quark_auth_state_v1';

  final FlutterSecureStorage _storage;

  bool get _useSharedPreferencesOnThisPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    final encoded = jsonEncode(value);
    if (_useSharedPreferencesOnThisPlatform) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, encoded);
      return;
    }
    await _storage.write(key: key, value: encoded);
  }

  Future<Map<String, dynamic>?> readJson(String key) async {
    final raw = _useSharedPreferencesOnThisPlatform
        ? (await SharedPreferences.getInstance()).getString(key)
        : await _storage.read(key: key);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<void> delete(String key) async {
    if (_useSharedPreferencesOnThisPlatform) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      return;
    }
    await _storage.delete(key: key);
  }
}

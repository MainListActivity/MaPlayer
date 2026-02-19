import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String quarkAuthKey = 'quark_auth_state_v1';

  final FlutterSecureStorage _storage;

  Future<void> writeJson(String key, Map<String, dynamic> value) {
    return _storage.write(key: key, value: jsonEncode(value));
  }

  Future<Map<String, dynamic>?> readJson(String key) async {
    final raw = await _storage.read(key: key);
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

  Future<void> delete(String key) => _storage.delete(key: key);
}

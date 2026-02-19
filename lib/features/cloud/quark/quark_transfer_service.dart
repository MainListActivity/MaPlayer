import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';

class QuarkTransferService {
  QuarkTransferService({
    required QuarkAuthService authService,
    http.Client? httpClient,
    Uri? baseUri,
  }) : _authService = authService,
       _http = httpClient ?? http.Client(),
       _baseUri = baseUri ?? Uri.parse('https://drive.quark.cn/1/clouddrive/');

  final QuarkAuthService _authService;
  final http.Client _http;
  final Uri _baseUri;

  Future<QuarkSavedFile> saveShareToMyDrive(
    QuarkShareRef shareRef,
    String targetDir,
  ) async {
    final auth = await _authService.ensureValidToken();
    final uri = _baseUri.resolve('share/save');
    final response = await _http.post(
      uri,
      headers: _authHeaders(auth),
      body: jsonEncode(<String, dynamic>{
        'shareUrl': shareRef.shareUrl,
        'targetDir': targetDir,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('Share save failed', code: 'SAVE_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final fileId = data['fileId']?.toString() ?? '';
    final fileName =
        data['fileName']?.toString() ?? shareRef.fileName ?? 'unknown';
    if (fileId.isEmpty) {
      throw QuarkException('Save result missing fileId', code: 'SAVE_PAYLOAD');
    }
    return QuarkSavedFile(
      fileId: fileId,
      fileName: fileName,
      parentDir: targetDir,
    );
  }

  Future<QuarkPlayableFile> resolvePlayableFile(String savedFileId) async {
    final auth = await _authService.ensureValidToken();
    final uri = _baseUri.resolve('file/play?file_id=$savedFileId');
    final response = await _http.get(uri, headers: _authHeaders(auth));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException(
        'Resolve playable file failed',
        code: 'PLAYABLE_FAILED',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final url = data['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw QuarkException('Playable URL missing', code: 'PLAYABLE_PAYLOAD');
    }

    final headers = <String, String>{};
    final headerJson = data['headers'];
    if (headerJson is Map) {
      for (final entry in headerJson.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }

    return QuarkPlayableFile(
      url: url,
      headers: headers,
      subtitle: data['subtitle']?.toString(),
    );
  }

  Map<String, String> _authHeaders(QuarkAuthState auth) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${auth.accessToken}',
    };
    if (auth.cookie != null && auth.cookie!.isNotEmpty) {
      headers['Cookie'] = auth.cookie!;
    }
    return headers;
  }
}

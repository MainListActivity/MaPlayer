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

  Future<QuarkFolderLookupResult> findOrCreateShowFolder(
    String rootDir,
    String showDirName,
  ) async {
    final auth = await _authService.ensureValidToken();
    final rootFolder = await _findOrCreateFolderByPath(auth, rootDir);
    final showFolder = await _findChildFolderByName(
      auth,
      rootFolder.fileId,
      showDirName,
    );
    if (showFolder != null) {
      return QuarkFolderLookupResult(
        folderId: showFolder.fileId,
        folderName: showFolder.fileName,
        created: false,
        path: '$rootDir/$showDirName',
      );
    }

    final createdFolder = await _createFolder(
      auth,
      rootFolder.fileId,
      showDirName,
    );
    return QuarkFolderLookupResult(
      folderId: createdFolder.fileId,
      folderName: createdFolder.fileName,
      created: true,
      path: '$rootDir/$showDirName',
    );
  }

  Future<List<QuarkFileEntry>> listFilesInFolder(String folderId) async {
    final auth = await _authService.ensureValidToken();
    final uri = _baseUri.resolve('file/list?folder_id=$folderId');
    final response = await _http.get(uri, headers: _authHeaders(auth));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('List files failed', code: 'LIST_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'];
    final list = _extractList(data);
    return list.map(_entryFromJson).toList();
  }

  Future<QuarkSavedFile> saveShareToFolder(
    QuarkShareRef shareRef,
    String folderId,
  ) async {
    final auth = await _authService.ensureValidToken();
    final uri = _baseUri.resolve('share/save');
    final response = await _http.post(
      uri,
      headers: _authHeaders(auth),
      body: jsonEncode(<String, dynamic>{
        'shareUrl': shareRef.shareUrl,
        'targetFolderId': folderId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('Share save failed', code: 'SAVE_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final fileId = data['fileId']?.toString() ?? data['taskId']?.toString() ?? '';
    final fileName =
        data['fileName']?.toString() ?? shareRef.fileName ?? 'unknown';
    if (fileId.isEmpty) {
      throw QuarkException('Save result missing fileId', code: 'SAVE_PAYLOAD');
    }
    return QuarkSavedFile(
      fileId: fileId,
      fileName: fileName,
      parentDir: '',
      parentFolderId: folderId,
    );
  }

  Future<QuarkSavedFile> saveShareToMyDrive(
    QuarkShareRef shareRef,
    String targetDir,
  ) async {
    final folder = await _findOrCreateFolderByPath(
      await _authService.ensureValidToken(),
      targetDir,
    );
    final saved = await saveShareToFolder(shareRef, folder.fileId);
    return QuarkSavedFile(
      fileId: saved.fileId,
      fileName: saved.fileName,
      parentDir: targetDir,
      parentFolderId: folder.fileId,
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

  Future<QuarkFileEntry> _findOrCreateFolderByPath(
    QuarkAuthState auth,
    String rawPath,
  ) async {
    final parts = rawPath
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    var currentFolderId = '0';
    var currentName = '/';
    for (final part in parts) {
      final existing = await _findChildFolderByName(auth, currentFolderId, part);
      if (existing != null) {
        currentFolderId = existing.fileId;
        currentName = existing.fileName;
        continue;
      }
      final created = await _createFolder(auth, currentFolderId, part);
      currentFolderId = created.fileId;
      currentName = created.fileName;
    }
    return QuarkFileEntry(
      fileId: currentFolderId,
      fileName: currentName,
      isDirectory: true,
    );
  }

  Future<QuarkFileEntry?> _findChildFolderByName(
    QuarkAuthState auth,
    String parentFolderId,
    String name,
  ) async {
    final uri = _baseUri.resolve('file/list?folder_id=$parentFolderId');
    final response = await _http.get(uri, headers: _authHeaders(auth));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('List files failed', code: 'LIST_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final list = _extractList(body['data']);
    for (final item in list) {
      final entry = _entryFromJson(item);
      if (entry.isDirectory && entry.fileName == name) {
        return entry;
      }
    }
    return null;
  }

  Future<QuarkFileEntry> _createFolder(
    QuarkAuthState auth,
    String parentFolderId,
    String folderName,
  ) async {
    final uri = _baseUri.resolve('file/mkdir');
    final response = await _http.post(
      uri,
      headers: _authHeaders(auth),
      body: jsonEncode(<String, dynamic>{
        'parentFolderId': parentFolderId,
        'folderName': folderName,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('Create folder failed', code: 'MKDIR_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final fileId =
        data['fileId']?.toString() ?? data['folderId']?.toString() ?? '';
    if (fileId.isEmpty) {
      throw QuarkException('Create folder payload invalid', code: 'MKDIR_PAYLOAD');
    }
    return QuarkFileEntry(
      fileId: fileId,
      fileName: data['fileName']?.toString() ?? folderName,
      isDirectory: true,
    );
  }

  List<Map<String, dynamic>> _extractList(Object? data) {
    if (data is Map<String, dynamic>) {
      final list = data['list'];
      if (list is List) {
        return list.whereType<Map>().map(Map<String, dynamic>.from).toList();
      }
    } else if (data is List) {
      return data.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    return const <Map<String, dynamic>>[];
  }

  QuarkFileEntry _entryFromJson(Map<String, dynamic> data) {
    final isDirectory =
        data['is_dir'] == true ||
        data['isDir'] == true ||
        data['category']?.toString() == 'folder' ||
        data['type']?.toString() == 'folder';
    return QuarkFileEntry(
      fileId:
          data['fileId']?.toString() ??
          data['fid']?.toString() ??
          data['id']?.toString() ??
          '',
      fileName:
          data['fileName']?.toString() ??
          data['name']?.toString() ??
          'unknown',
      isDirectory: isDirectory,
      size: (data['size'] as num?)?.toInt(),
      updatedAtEpochMs:
          (data['updatedAt'] as num?)?.toInt() ??
          (data['updated_at'] as num?)?.toInt(),
    );
  }

  Map<String, String> _authHeaders(QuarkAuthState auth) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (auth.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${auth.accessToken}';
    }
    if (auth.cookie != null && auth.cookie!.isNotEmpty) {
      headers['Cookie'] = auth.cookie!;
    }
    return headers;
  }
}

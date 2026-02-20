import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_playback_cookie_provider.dart';

class QuarkTransferService {
  QuarkTransferService({
    required QuarkAuthService authService,
    http.Client? httpClient,
    Uri? baseUri,
    QuarkPlaybackCookieProvider? playbackCookieProvider,
  }) : _authService = authService,
       _http = httpClient ?? http.Client(),
       _baseUri =
           baseUri ?? Uri.parse('https://drive-pc.quark.cn/1/clouddrive/'),
       _playbackCookieProvider =
           playbackCookieProvider ?? QuarkHeadlessWebViewCookieProvider();

  final QuarkAuthService _authService;
  final http.Client _http;
  final Uri _baseUri;
  final QuarkPlaybackCookieProvider _playbackCookieProvider;
  static const _desktopChromeUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/145.0.0.0 Safari/537.36';

  List<Uri> get _baseUriCandidates => <Uri>[
    _baseUri,
    Uri.parse('https://drive.quark.cn/1/clouddrive/'),
    Uri.parse('https://pan.quark.cn/1/clouddrive/'),
  ];

  void _logTransfer(String message) {
    debugPrint('[QuarkTransfer] $message');
  }

  Future<QuarkFolderLookupResult> findOrCreateShowFolder(
    String rootDir,
    String showDirName,
  ) async {
    final normalizedShowDirName = showDirName.trim().isEmpty
        ? 'untitled_show'
        : showDirName.trim();
    final auth = await _authService.ensureValidToken();
    final rootFolder = await _findOrCreateFolderByPath(auth, rootDir);
    final showFolder = await _findChildFolderByName(
      auth,
      rootFolder.fileId,
      normalizedShowDirName,
    );
    if (showFolder != null) {
      return QuarkFolderLookupResult(
        folderId: showFolder.fileId,
        folderName: showFolder.fileName,
        created: false,
        path: '$rootDir/$normalizedShowDirName',
      );
    }

    final createdFolder = await _createFolder(
      auth,
      rootFolder.fileId,
      normalizedShowDirName,
    );
    return QuarkFolderLookupResult(
      folderId: createdFolder.fileId,
      folderName: createdFolder.fileName,
      created: true,
      path: '$rootDir/$normalizedShowDirName',
    );
  }

  Future<List<QuarkShareFileEntry>> listShareEpisodes(String shareUrl) async {
    final shareId = _extractShareId(shareUrl);
    if (shareId.isEmpty) {
      throw QuarkException('Invalid share url', code: 'SHARE_URL_INVALID');
    }
    final stoken = await _requestShareToken(shareId);
    final all = await _collectShareFiles(
      pwdId: shareId,
      stoken: stoken,
      pdirFid: '0',
    );
    final videos = all
        .where((e) => !e.isDirectory && _looksLikeVideo(e.fileName))
        .toList();
    videos.sort((a, b) => _naturalCompare(a.fileName, b.fileName));
    return videos;
  }

  Future<void> clearFolder(String folderId) async {
    final files = await listFilesInFolder(folderId);
    final deleteIds = files
        .where((e) => !e.isDirectory)
        .map((e) => e.fileId)
        .toList();
    if (deleteIds.isEmpty) return;
    await _deleteFiles(deleteIds);
  }

  Future<void> clearFolderExcept(String folderId, String keepFileId) async {
    final files = await listFilesInFolder(folderId);
    final deleteIds = files
        .where((e) => !e.isDirectory && e.fileId != keepFileId)
        .map((e) => e.fileId)
        .toList();
    if (deleteIds.isEmpty) return;
    await _deleteFiles(deleteIds);
  }

  Future<void> saveShareEpisodeToFolder({
    required String shareUrl,
    required QuarkShareFileEntry episode,
    required String folderId,
  }) async {
    final auth = await _authService.ensureValidToken();
    final shareId = _extractShareId(shareUrl);
    if (shareId.isEmpty) {
      throw QuarkException('Invalid share url', code: 'SHARE_URL_INVALID');
    }
    final stoken = await _requestShareToken(shareId);
    final latest = await _resolveLatestShareEpisode(
      pwdId: shareId,
      stoken: stoken,
      fallback: episode,
    );
    final uri = _buildShareSaveUri(_baseUri);
    final response = await _http.post(
      uri,
      headers: _authHeaders(auth),
      body: jsonEncode(<String, dynamic>{
        'fid_list': <String>[latest.fid],
        'fid_token_list': <String>[latest.shareFidToken],
        'to_pdir_fid': folderId,
        'pwd_id': shareId,
        'stoken': stoken,
        'pdir_fid': latest.pdirFid,
        'scene': 'link',
      }),
    );
    _logTransfer(
      'save selected: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException(
        'Save selected episode failed: ${response.statusCode}',
        code: 'SAVE_FAILED',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final code = body['code'];
    if (code is num && code.toInt() != 0) {
      throw QuarkException(
        'Save selected episode failed(code=${code.toInt()}): ${body['message']}',
        code: 'SAVE_FAILED',
      );
    }
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final taskId =
        data['task_id']?.toString() ??
        data['taskId']?.toString() ??
        data['save_as']?['task_id']?.toString() ??
        '';
    if (taskId.isNotEmpty) {
      await _waitTaskDone(taskId);
    }
  }

  Future<void> _waitTaskDone(String taskId) async {
    final auth = await _authService.ensureValidToken();
    var retryIndex = 0;
    while (retryIndex < 20) {
      final uri = _buildTaskUri(
        _baseUri,
        taskId: taskId,
        retryIndex: retryIndex,
      );
      final response = await _http.get(uri, headers: _authHeaders(auth));
      _logTransfer(
        'task poll: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final code = body['code'];
        if (code is num && code.toInt() == 0) {
          final data = Map<String, dynamic>.from(
            body['data'] as Map? ?? <String, dynamic>{},
          );
          final status = (data['status'] as num?)?.toInt() ?? -1;
          if (status == 2) {
            return;
          }
          if (status == 3 || status == 4) {
            throw QuarkException(
              'Save task failed(status=$status): ${data['task_title'] ?? ''}',
              code: 'SAVE_TASK_FAILED',
            );
          }
        }
      }
      retryIndex += 1;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw QuarkException('Save task timeout', code: 'SAVE_TASK_TIMEOUT');
  }

  Future<QuarkShareFileEntry> _resolveLatestShareEpisode({
    required String pwdId,
    required String stoken,
    required QuarkShareFileEntry fallback,
  }) async {
    try {
      final latestList = await _collectShareFiles(
        pwdId: pwdId,
        stoken: stoken,
        pdirFid: '0',
      );
      for (final item in latestList) {
        if (item.fid == fallback.fid) {
          return item;
        }
      }
      for (final item in latestList) {
        if (item.fileName == fallback.fileName) {
          return item;
        }
      }
    } catch (_) {
      // Keep fallback when share listing refresh fails.
    }
    return fallback;
  }

  Future<List<QuarkFileEntry>> listFilesInFolder(String folderId) async {
    final auth = await _authService.ensureValidToken();
    http.Response? lastResponse;
    Uri? lastUri;
    for (final base in _baseUriCandidates) {
      final uri = _buildFileSortUri(base, folderId);
      final response = await _http.get(uri, headers: _authHeaders(auth));
      lastResponse = response;
      lastUri = uri;
      _logTransfer(
        'list files: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final data = body['data'];
        final list = _extractList(data);
        return list.map(_entryFromJson).toList();
      }
    }
    throw QuarkException(
      'List files failed '
      '(uri=${lastUri?.toString() ?? 'unknown'}, '
      'status=${lastResponse?.statusCode ?? -1}, '
      'body=${_snippet(lastResponse?.body ?? '')})',
      code: 'LIST_FAILED',
    );
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
    final fileId =
        data['fileId']?.toString() ?? data['taskId']?.toString() ?? '';
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
    http.Response? lastResponse;
    Uri? lastUri;

    for (final base in _baseUriCandidates) {
      final uri = _buildPlayV2Uri(base);
      final response = await _http.post(
        uri,
        headers: _authHeaders(auth),
        body: jsonEncode(<String, dynamic>{
          'fid': savedFileId,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        }),
      );
      lastResponse = response;
      lastUri = uri;
      _logTransfer(
        'resolve playable: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is num && code.toInt() != 0) {
        continue;
      }

      final data = Map<String, dynamic>.from(
        body['data'] as Map? ?? <String, dynamic>{},
      );
      final url = _pickPlayableUrlFromVideoList(data);
      if (url.isEmpty) {
        throw QuarkException('Playable URL missing', code: 'PLAYABLE_PAYLOAD');
      }
      final webViewResolved = await _playbackCookieProvider.resolveForVideo(
        savedFileId,
      );
      final webViewCookie = webViewResolved?.cookieHeader;
      final webViewM3u8 = webViewResolved?.m3u8Url?.trim() ?? '';
      final playableUrl = webViewM3u8.isNotEmpty ? webViewM3u8 : url;
      if (webViewM3u8.isNotEmpty) {
        _logTransfer('resolve playable: using m3u8 from webview=$webViewM3u8');
      }
      final latestVideoAuth = _extractVideoAuthFromSetCookie(response.headers);
      if (latestVideoAuth != null && latestVideoAuth.isNotEmpty) {
        _logTransfer(
          'resolve playable: refreshed Video-Auth from set-cookie, Video-Auth=$latestVideoAuth',
        );
      }

      final headers = _mergePlayableHeaders(
        auth: auth,
        resolved: _extractPlayableHeaders(data),
        webViewCookie: webViewCookie,
        latestVideoAuth: latestVideoAuth,
      );

      return QuarkPlayableFile(
        url: playableUrl,
        headers: headers,
        subtitle: data['subtitle']?.toString(),
      );
    }

    if (lastResponse != null &&
        lastResponse.statusCode >= 200 &&
        lastResponse.statusCode < 300) {
      try {
        final body = jsonDecode(lastResponse.body) as Map<String, dynamic>;
        throw QuarkException(
          'Resolve playable file failed(code=${body['code']}): ${body['message']}',
          code: 'PLAYABLE_FAILED',
        );
      } catch (_) {}
    }

    throw QuarkException(
      'Resolve playable file failed '
      '(uri=${lastUri?.toString() ?? 'unknown'}, '
      'status=${lastResponse?.statusCode ?? -1}, '
      'body=${_snippet(lastResponse?.body ?? '')})',
      code: 'PLAYABLE_FAILED',
    );
  }

  Future<void> _deleteFiles(List<String> fileIds) async {
    if (fileIds.isEmpty) return;
    final auth = await _authService.ensureValidToken();
    for (var i = 0; i < fileIds.length; i += 100) {
      final batch = fileIds.sublist(i, (i + 100).clamp(0, fileIds.length));
      final uri = _buildDeleteUri(_baseUri);
      final response = await _http.post(
        uri,
        headers: _authHeaders(auth),
        body: jsonEncode(<String, dynamic>{
          'action_type': 2,
          'filelist': batch,
          'exclude_fids': const <String>[],
        }),
      );
      _logTransfer(
        'delete files: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw QuarkException('Delete files failed', code: 'DELETE_FAILED');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is num && code.toInt() != 0) {
        throw QuarkException(
          'Delete files failed(code=${code.toInt()}): ${body['message']}',
          code: 'DELETE_FAILED',
        );
      }
    }
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
      final existing = await _findChildFolderByName(
        auth,
        currentFolderId,
        part,
      );
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
    final list = await listFilesInFolder(parentFolderId);
    for (final item in list) {
      final entry = item;
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
    http.Response? lastResponse;
    Uri? lastUri;
    for (final base in _baseUriCandidates) {
      final uri = _buildCreateFolderUri(base);
      final response = await _http.post(
        uri,
        headers: _authHeaders(auth),
        body: jsonEncode(<String, dynamic>{
          'pdir_fid': parentFolderId,
          'file_name': folderName,
          'dir_path': '',
          'dir_init_lock': false,
        }),
      );
      lastResponse = response;
      lastUri = uri;
      _logTransfer(
        'mkdir: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );
      Map<String, dynamic>? body;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          body = decoded;
        } else if (decoded is Map) {
          body = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // Keep body null when response is not valid json.
      }
      final status = response.statusCode;
      final isSuccessStatus = status >= 200 && status < 300;

      final code = body?['code'];
      if (code is num && code.toInt() == 23008) {
        final existing = await _findChildFolderByName(
          auth,
          parentFolderId,
          folderName,
        );
        if (existing != null) {
          return existing;
        }
        continue;
      }
      if (!isSuccessStatus) {
        continue;
      }
      if (body == null) {
        continue;
      }
      if (code is num && code.toInt() != 0) {
        continue;
      }
      final existing = await _findChildFolderByName(
        auth,
        parentFolderId,
        folderName,
      );
      if (existing == null) {
        continue;
      }
      return existing;
    }
    throw QuarkException(
      'Create folder failed '
      '(uri=${lastUri?.toString() ?? 'unknown'}, '
      'status=${lastResponse?.statusCode ?? -1}, '
      'body=${_snippet(lastResponse?.body ?? '')})',
      code: 'MKDIR_FAILED',
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
        data['dir'] == true ||
        data['file'] == false ||
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
          data['file_name']?.toString() ??
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
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ..._baseHeaders(),
    };
    if (auth.accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${auth.accessToken}';
    }
    if (auth.cookie != null && auth.cookie!.isNotEmpty) {
      headers['Cookie'] = auth.cookie!;
      final tfstk = _extractCookieValue(auth.cookie!, 'tfstk');
      if (tfstk != null && tfstk.isNotEmpty) {
        headers['x-csrf-token'] = tfstk;
      }
    }
    return headers;
  }

  String _snippet(String text, {int max = 180}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= max) {
      return normalized;
    }
    return '${normalized.substring(0, max)}...';
  }

  Future<String> _requestShareToken(String pwdId) async {
    final uri = _buildShareTokenUri(_baseUri);
    final response = await _http.post(
      uri,
      headers: <String, String>{
        ..._baseHeaders(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'pwd_id': pwdId, 'passcode': ''}),
    );
    _logTransfer(
      'share token: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuarkException('Share token failed', code: 'SHARE_TOKEN_FAILED');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final code = body['code'];
    if (code is num && code.toInt() != 0) {
      throw QuarkException(
        'Share token failed(code=${code.toInt()}): ${body['message']}',
        code: 'SHARE_TOKEN_FAILED',
      );
    }
    final data = Map<String, dynamic>.from(
      body['data'] as Map? ?? <String, dynamic>{},
    );
    final stoken = data['stoken']?.toString() ?? '';
    if (stoken.isEmpty) {
      throw QuarkException(
        'Share token payload invalid',
        code: 'SHARE_TOKEN_PAYLOAD',
      );
    }
    return stoken;
  }

  Future<List<QuarkShareFileEntry>> _collectShareFiles({
    required String pwdId,
    required String stoken,
    required String pdirFid,
  }) async {
    final result = <QuarkShareFileEntry>[];
    final queue = <String>[pdirFid];
    final visited = <String>{};
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (!visited.add(current)) continue;
      final list = await _listShareDir(
        pwdId: pwdId,
        stoken: stoken,
        pdirFid: current,
      );
      for (final item in list) {
        result.add(item);
        if (item.isDirectory) {
          queue.add(item.fid);
        }
      }
    }
    return result;
  }

  Future<List<QuarkShareFileEntry>> _listShareDir({
    required String pwdId,
    required String stoken,
    required String pdirFid,
  }) async {
    final list = <QuarkShareFileEntry>[];
    var page = 1;
    while (true) {
      final uri = _buildShareDetailUri(
        _baseUri,
        pwdId: pwdId,
        stoken: stoken,
        pdirFid: pdirFid,
        page: page,
      );
      final response = await _http.get(uri, headers: _baseHeaders());
      _logTransfer(
        'share detail: uri=$uri status=${response.statusCode} body=${_snippet(response.body)}',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw QuarkException(
          'Share detail failed',
          code: 'SHARE_DETAIL_FAILED',
        );
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is num && code.toInt() != 0) {
        throw QuarkException(
          'Share detail failed(code=${code.toInt()}): ${body['message']}',
          code: 'SHARE_DETAIL_FAILED',
        );
      }
      final data = Map<String, dynamic>.from(
        body['data'] as Map? ?? <String, dynamic>{},
      );
      final rawList = data['list'];
      if (rawList is! List || rawList.isEmpty) {
        break;
      }
      final entries = rawList
          .whereType<Map>()
          .map((e) {
            final item = Map<String, dynamic>.from(e);
            final fid = item['fid']?.toString() ?? '';
            final name = item['file_name']?.toString() ?? '';
            final token = item['share_fid_token']?.toString() ?? '';
            final parent = item['pdir_fid']?.toString() ?? pdirFid;
            final isDir = item['dir'] == true || item['file'] == false;
            return QuarkShareFileEntry(
              fid: fid,
              fileName: name,
              pdirFid: parent,
              shareFidToken: token,
              isDirectory: isDir,
              updatedAtEpochMs: (item['updated_at'] as num?)?.toInt(),
            );
          })
          .where((e) => e.fid.isNotEmpty && e.fileName.isNotEmpty)
          .toList();
      list.addAll(entries);
      if (entries.length < 50) {
        break;
      }
      page += 1;
    }
    return list;
  }

  String _extractShareId(String shareUrl) {
    final uri = Uri.tryParse(shareUrl);
    if (uri == null) return '';
    if (uri.pathSegments.length < 2 || uri.pathSegments.first != 's') return '';
    return uri.pathSegments[1];
  }

  bool _looksLikeVideo(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m3u8') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.flv');
  }

  int _naturalCompare(String a, String b) {
    final tokenA = _splitTokens(a);
    final tokenB = _splitTokens(b);
    final len = tokenA.length < tokenB.length ? tokenA.length : tokenB.length;
    for (var i = 0; i < len; i++) {
      final left = tokenA[i];
      final right = tokenB[i];
      final leftNum = int.tryParse(left);
      final rightNum = int.tryParse(right);
      if (leftNum != null && rightNum != null) {
        final cmp = leftNum.compareTo(rightNum);
        if (cmp != 0) return cmp;
      } else {
        final cmp = left.compareTo(right);
        if (cmp != 0) return cmp;
      }
    }
    return tokenA.length.compareTo(tokenB.length);
  }

  List<String> _splitTokens(String value) {
    return value
        .splitMapJoin(
          RegExp(r'(\d+)'),
          onMatch: (m) => '|${m.group(0)}|',
          onNonMatch: (n) => n,
        )
        .split('|')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Uri _buildFileSortUri(Uri base, String folderId) {
    final uri = base.resolve('file/sort');
    return uri.replace(
      queryParameters: <String, String>{
        'pr': 'ucpro',
        'fr': 'pc',
        'uc_param_str': '',
        'pdir_fid': folderId,
        '_page': '1',
        '_size': '50',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,updated_at:desc',
        'fetch_all_file': '1',
        'fetch_risk_file_name': '1',
      },
    );
  }

  Uri _buildCreateFolderUri(Uri base) {
    final uri = base.resolve('file');
    return uri.replace(
      queryParameters: <String, String>{
        'pr': 'ucpro',
        'fr': 'pc',
        'uc_param_str': '',
        'app': 'clouddrive',
      },
    );
  }

  Uri _buildShareTokenUri(Uri base) {
    return base
        .resolve('share/sharepage/token')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
          },
        );
  }

  Uri _buildShareDetailUri(
    Uri base, {
    required String pwdId,
    required String stoken,
    required String pdirFid,
    required int page,
  }) {
    return base
        .resolve('share/sharepage/detail')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
            'pwd_id': pwdId,
            'stoken': stoken,
            'pdir_fid': pdirFid,
            'force': '0',
            '_page': '$page',
            '_size': '50',
            '_fetch_banner': '0',
            '_fetch_share': '1',
            '_fetch_total': '1',
            '_sort': 'file_type:asc,updated_at:desc',
          },
        );
  }

  Uri _buildShareSaveUri(Uri base) {
    return base
        .resolve('share/sharepage/save')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
            'app': 'clouddrive',
            '__dt': '${(Random().nextInt(4) + 1) * 60 * 1000}',
            '__t': '${DateTime.now().millisecondsSinceEpoch}',
          },
        );
  }

  Uri _buildDeleteUri(Uri base) {
    return base
        .resolve('file/delete')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
          },
        );
  }

  Uri _buildPlayV2Uri(Uri base) {
    return base
        .resolve('file/v2/play')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
          },
        );
  }

  Uri _buildTaskUri(
    Uri base, {
    required String taskId,
    required int retryIndex,
  }) {
    return base
        .resolve('task')
        .replace(
          queryParameters: <String, String>{
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
            'task_id': taskId,
            'retry_index': '$retryIndex',
          },
        );
  }

  Map<String, String> _baseHeaders() => <String, String>{
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
    'Origin': 'https://pan.quark.cn',
    'Referer': 'https://pan.quark.cn/',
    'User-Agent': _desktopChromeUa,
  };

  String? _extractCookieValue(String header, String key) {
    for (final segment in header.split(';')) {
      final trimmed = segment.trim();
      if (!trimmed.contains('=')) continue;
      final idx = trimmed.indexOf('=');
      final name = trimmed.substring(0, idx).trim();
      if (name == key) {
        return trimmed.substring(idx + 1);
      }
    }
    return null;
  }

  String _pickPlayableUrlFromVideoList(Map<String, dynamic> data) {
    final list = data['video_list'];
    if (list is! List) return '';
    final videos = list
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    if (videos.isEmpty) return '';

    const preferred = <String>['super', 'high', 'normal', 'low', '2k', '4k'];
    for (final resolution in preferred) {
      for (final item in videos) {
        final current = item['resolution']?.toString().toLowerCase() ?? '';
        if (current != resolution) continue;
        final info = Map<String, dynamic>.from(
          item['video_info'] as Map? ?? <String, dynamic>{},
        );
        final url = info['url']?.toString() ?? '';
        if (url.isNotEmpty) return url;
      }
    }

    for (final item in videos) {
      final info = Map<String, dynamic>.from(
        item['video_info'] as Map? ?? <String, dynamic>{},
      );
      final url = info['url']?.toString() ?? '';
      if (url.isNotEmpty) return url;
    }
    return '';
  }

  Map<String, String> _extractPlayableHeaders(Map<String, dynamic> data) {
    final headers = <String, String>{};
    final levelHeaders = data['headers'];
    if (levelHeaders is Map) {
      for (final entry in levelHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    final list = data['video_list'];
    if (list is List) {
      for (final entry in list.whereType<Map>()) {
        final item = Map<String, dynamic>.from(entry);
        final info = Map<String, dynamic>.from(
          item['video_info'] as Map? ?? <String, dynamic>{},
        );
        final infoHeaders = info['headers'];
        if (infoHeaders is Map) {
          for (final h in infoHeaders.entries) {
            headers[h.key.toString()] = h.value.toString();
          }
          if (headers.isNotEmpty) {
            return headers;
          }
        }
      }
    }
    return headers;
  }

  Map<String, String> _mergePlayableHeaders({
    required QuarkAuthState auth,
    required Map<String, String> resolved,
    String? webViewCookie,
    String? latestVideoAuth,
  }) {
    final merged = Map<String, String>.from(resolved);
    _setHeaderCaseInsensitive(merged, 'User-Agent', _desktopChromeUa);
    final authCookie = auth.cookie?.trim() ?? '';
    final resolvedCookie = _getHeaderCaseInsensitive(merged, 'Cookie')?.trim();
    var cookie = webViewCookie?.trim() ?? '';
    if (cookie.isEmpty) {
      cookie = authCookie.isNotEmpty ? authCookie : (resolvedCookie ?? '');
    }
    if (latestVideoAuth != null && latestVideoAuth.isNotEmpty) {
      cookie = _upsertCookie(cookie, 'Video-Auth', latestVideoAuth);
    }
    if (cookie.isNotEmpty) {
      _setHeaderCaseInsensitive(merged, 'Cookie', cookie);
    }
    return merged;
  }

  String? _extractVideoAuthFromSetCookie(Map<String, String> headers) {
    final setCookie = _getHeaderCaseInsensitive(headers, 'set-cookie');
    if (setCookie == null || setCookie.isEmpty) {
      return null;
    }
    final match = RegExp(
      r'(^|[,\s])Video-Auth=([^;,\s]+)',
      caseSensitive: false,
    ).firstMatch(setCookie);
    return match?.group(2);
  }

  String? _getHeaderCaseInsensitive(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return entry.value;
      }
    }
    return null;
  }

  String _upsertCookie(String cookieHeader, String key, String value) {
    final cookies = <String, String>{};
    for (final segment in cookieHeader.split(';')) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty || !trimmed.contains('=')) continue;
      final idx = trimmed.indexOf('=');
      final name = trimmed.substring(0, idx).trim();
      if (name.isEmpty) continue;
      cookies[name] = trimmed.substring(idx + 1).trim();
    }
    cookies[key] = value;
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _setHeaderCaseInsensitive(
    Map<String, String> headers,
    String name,
    String value,
  ) {
    final toRemove = <String>[];
    for (final key in headers.keys) {
      if (key.toLowerCase() == name.toLowerCase()) {
        toRemove.add(key);
      }
    }
    for (final key in toRemove) {
      headers.remove(key);
    }
    headers[name] = value;
  }
}

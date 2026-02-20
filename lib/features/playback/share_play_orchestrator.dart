import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_transfer_service.dart';
import 'package:ma_palyer/features/history/play_history_models.dart';
import 'package:ma_palyer/features/history/play_history_repository.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';

class SharePlayRequest {
  const SharePlayRequest({
    required this.shareUrl,
    required this.pageUrl,
    required this.title,
    this.coverUrl,
    this.coverHeaders,
    this.intro,
  });

  final String shareUrl;
  final String pageUrl;
  final String title;
  final String? coverUrl;
  final Map<String, String>? coverHeaders;
  final String? intro;
}

class EpisodeCandidate {
  const EpisodeCandidate({
    required this.fileId,
    required this.name,
    required this.selectedByDefault,
  });

  final String fileId;
  final String name;
  final bool selectedByDefault;
}

class PreparedEpisodeSelection {
  const PreparedEpisodeSelection({
    required this.request,
    required this.showDirName,
    required this.preferredFolderId,
    required this.episodes,
    required this.preferredFileId,
    required this.shareEpisodeMap,
  });

  final SharePlayRequest request;
  final String showDirName;
  final String? preferredFolderId;
  final List<EpisodeCandidate> episodes;
  final String? preferredFileId;
  final Map<String, QuarkShareFileEntry> shareEpisodeMap;
}

class SharePlayOrchestrator {
  SharePlayOrchestrator({
    QuarkAuthService? authService,
    QuarkTransferService? transferService,
    PlayHistoryRepository? historyRepository,
  }) : _authService = authService ?? QuarkAuthService(),
       _historyRepository = historyRepository ?? PlayHistoryRepository() {
    _transferService =
        transferService ?? QuarkTransferService(authService: _authService);
  }

  final QuarkAuthService _authService;
  late final QuarkTransferService _transferService;
  final PlayHistoryRepository _historyRepository;

  Future<PreparedEpisodeSelection> prepareEpisodes(
    SharePlayRequest request,
  ) async {
    _validateShareUrl(request.shareUrl);
    await _authService.ensureValidToken();

    final history = await _historyRepository.findByShareUrl(request.shareUrl);
    final showDirName = _showDirNameFor(request.title, request.shareUrl);
    final cached = history?.cachedEpisodes ?? const <PlayHistoryEpisode>[];

    List<QuarkShareFileEntry> shareEpisodes;
    try {
      shareEpisodes = await _transferService.listShareEpisodes(
        request.shareUrl,
      );
    } catch (_) {
      shareEpisodes = cached
          .map(
            (e) => QuarkShareFileEntry(
              fid: e.fileId,
              fileName: e.name,
              pdirFid: '0',
              shareFidToken: e.shareFidToken,
              isDirectory: false,
            ),
          )
          .toList();
    }

    if (shareEpisodes.isEmpty) {
      throw PlaybackException('分享链接中未找到可播放文件', code: 'EPISODE_EMPTY');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await _historyRepository.upsertByShareUrl(
      PlayHistoryItem(
        shareUrl: request.shareUrl,
        pageUrl: request.pageUrl,
        title: request.title,
        coverUrl: request.coverUrl ?? '',
        coverHeaders: request.coverHeaders ?? const <String, String>{},
        intro: request.intro ?? '',
        showDirName: showDirName,
        showFolderId: history?.showFolderId,
        lastEpisodeFileId: history?.lastEpisodeFileId,
        lastEpisodeName: history?.lastEpisodeName,
        cachedEpisodes: shareEpisodes
            .map(
              (e) => PlayHistoryEpisode(
                fileId: e.fid,
                name: e.fileName,
                shareFidToken: e.shareFidToken,
              ),
            )
            .toList(),
        updatedAtEpochMs: now,
      ),
    );

    final preferredFileId = history?.lastEpisodeFileId;
    final episodes = shareEpisodes
        .map(
          (e) => EpisodeCandidate(
            fileId: e.fid,
            name: e.fileName,
            selectedByDefault:
                preferredFileId != null && preferredFileId == e.fid,
          ),
        )
        .toList();

    return PreparedEpisodeSelection(
      request: request,
      showDirName: showDirName,
      preferredFolderId: history?.showFolderId,
      episodes: episodes,
      preferredFileId: preferredFileId,
      shareEpisodeMap: {for (final item in shareEpisodes) item.fid: item},
    );
  }

  Future<PlayableMedia> playEpisode(
    PreparedEpisodeSelection prepared,
    EpisodeCandidate selected,
  ) async {
    final selectedShareFile = prepared.shareEpisodeMap[selected.fileId];
    if (selectedShareFile == null) {
      throw PlaybackException('选集信息已失效，请重新打开选集', code: 'EPISODE_STALE');
    }

    final folder = await _resolveShowFolder(prepared);

    QuarkFileEntry? selectedSaved = await _findSavedFileByName(
      rootFolderId: folder.folderId,
      preferredName: selected.name,
    );
    if (selectedSaved == null) {
      await _transferService.clearFolder(folder.folderId);
      await _transferService.saveShareEpisodeToFolder(
        shareUrl: prepared.request.shareUrl,
        episode: selectedShareFile,
        folderId: folder.folderId,
      );
      selectedSaved = await _findSavedFileAfterTransfer(
        rootFolderId: folder.folderId,
        preferredName: selected.name,
      );
    }
    if (selectedSaved == null) {
      throw PlaybackException('转存后未找到选中剧集文件', code: 'EPISODE_SAVE_MISSING');
    }
    await _transferService.clearFolderExcept(
      folder.folderId,
      selectedSaved.fileId,
    );

    final playable = await _transferService.resolvePlayableFile(
      selectedSaved.fileId,
    );
    final media = PlayableMedia(
      url: playable.url,
      headers: playable.headers,
      subtitle: playable.subtitle,
      progressKey: '${prepared.request.shareUrl}:${selected.fileId}',
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    final current = await _historyRepository.findByShareUrl(
      prepared.request.shareUrl,
    );
    await _historyRepository.upsertByShareUrl(
      PlayHistoryItem(
        shareUrl: prepared.request.shareUrl,
        pageUrl: prepared.request.pageUrl,
        title: prepared.request.title,
        coverUrl: prepared.request.coverUrl ?? '',
        coverHeaders: prepared.request.coverHeaders ?? const <String, String>{},
        intro: prepared.request.intro ?? '',
        showDirName: prepared.showDirName,
        showFolderId: folder.folderId,
        lastEpisodeFileId: selected.fileId,
        lastEpisodeName: selected.name,
        cachedEpisodes: current?.cachedEpisodes ?? const <PlayHistoryEpisode>[],
        updatedAtEpochMs: now,
      ),
    );
    return media;
  }

  Future<QuarkFolderLookupResult> _resolveShowFolder(
    PreparedEpisodeSelection prepared,
  ) async {
    final savedFolderId = prepared.preferredFolderId?.trim() ?? '';
    if (savedFolderId.isNotEmpty) {
      try {
        await _transferService.listFilesInFolder(savedFolderId);
        return QuarkFolderLookupResult(
          folderId: savedFolderId,
          folderName: prepared.showDirName,
          created: false,
          path: '/MaPlayer/${prepared.showDirName}',
        );
      } catch (_) {
        // Fall through to locate folder by path when cached id is stale.
      }
    }
    return _transferService.findOrCreateShowFolder(
      '/MaPlayer',
      prepared.showDirName,
    );
  }

  Future<QuarkFileEntry?> _findSavedFileByName({
    required String rootFolderId,
    required String preferredName,
  }) async {
    final rootFiles = await _transferService.listFilesInFolder(rootFolderId);
    final direct = _pickSavedFile(rootFiles, preferredName);
    if (direct != null) {
      return direct;
    }
    final queue = <String>[
      ...rootFiles.where((e) => e.isDirectory).map((e) => e.fileId),
    ];
    final visited = <String>{rootFolderId};
    while (queue.isNotEmpty) {
      final folderId = queue.removeAt(0);
      if (!visited.add(folderId)) continue;
      final files = await _transferService.listFilesInFolder(folderId);
      final hit = _pickSavedFile(files, preferredName);
      if (hit != null) {
        return hit;
      }
      queue.addAll(files.where((e) => e.isDirectory).map((e) => e.fileId));
    }
    return null;
  }

  Future<QuarkFileEntry?> _findSavedFileAfterTransfer({
    required String rootFolderId,
    required String preferredName,
  }) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final rootFiles = await _transferService.listFilesInFolder(rootFolderId);
      final direct = _pickSavedFile(rootFiles, preferredName);
      if (direct != null) {
        return direct;
      }

      final queue = <String>[
        ...rootFiles.where((e) => e.isDirectory).map((e) => e.fileId),
      ];
      final visited = <String>{rootFolderId};
      while (queue.isNotEmpty) {
        final folderId = queue.removeAt(0);
        if (!visited.add(folderId)) continue;
        final files = await _transferService.listFilesInFolder(folderId);
        final hit = _pickSavedFile(files, preferredName);
        if (hit != null) {
          return hit;
        }
        queue.addAll(files.where((e) => e.isDirectory).map((e) => e.fileId));
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
    return null;
  }

  QuarkFileEntry? _pickSavedFile(
    List<QuarkFileEntry> files,
    String preferredName,
  ) {
    for (final file in files) {
      if (!file.isDirectory && file.fileName == preferredName) {
        return file;
      }
    }
    for (final file in files) {
      if (!file.isDirectory && _looksLikeVideo(file.fileName)) {
        return file;
      }
    }
    return null;
  }

  void _validateShareUrl(String shareUrl) {
    final uri = Uri.tryParse(shareUrl);
    if (uri == null ||
        uri.host != 'pan.quark.cn' ||
        !uri.path.startsWith('/s/')) {
      throw PlaybackException('无效夸克分享链接', code: 'SHARE_URL_INVALID');
    }
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

  String _showDirNameFor(String title, String shareUrl) {
    final trimmed = title.trim();
    final seed = trimmed.isNotEmpty ? trimmed : _shareId(shareUrl);
    return seed.replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9._-]'), '_');
  }

  String _shareId(String shareUrl) {
    final uri = Uri.tryParse(shareUrl);
    if (uri == null) return 'unknown';
    final parts = uri.pathSegments;
    if (parts.length >= 2) return parts[1];
    return 'unknown';
  }
}

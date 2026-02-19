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
    this.intro,
  });

  final String shareUrl;
  final String pageUrl;
  final String title;
  final String? coverUrl;
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
    required this.folder,
    required this.episodes,
    required this.preferredFileId,
  });

  final SharePlayRequest request;
  final String showDirName;
  final QuarkFolderLookupResult folder;
  final List<EpisodeCandidate> episodes;
  final String? preferredFileId;
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
    final folder = await _transferService.findOrCreateShowFolder(
      '/MaPlayer',
      showDirName,
    );

    var files = await _transferService.listFilesInFolder(folder.folderId);
    if (_shouldTransfer(files)) {
      await _transferService.saveShareToFolder(
        QuarkShareRef(shareUrl: request.shareUrl, fileName: request.title),
        folder.folderId,
      );
      files = await _transferService.listFilesInFolder(folder.folderId);
    }

    final episodes = _toEpisodeCandidates(files, history?.lastEpisodeFileId);
    if (episodes.isEmpty) {
      throw PlaybackException('转存目录中未找到可播放文件', code: 'EPISODE_EMPTY');
    }

    return PreparedEpisodeSelection(
      request: request,
      showDirName: showDirName,
      folder: folder,
      episodes: episodes,
      preferredFileId: history?.lastEpisodeFileId,
    );
  }

  Future<PlayableMedia> playEpisode(
    PreparedEpisodeSelection prepared,
    EpisodeCandidate selected,
  ) async {
    final playable = await _transferService.resolvePlayableFile(selected.fileId);

    final media = PlayableMedia(
      url: playable.url,
      headers: playable.headers,
      subtitle: playable.subtitle,
      progressKey: '${prepared.request.shareUrl}:${selected.fileId}',
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    await _historyRepository.upsertByShareUrl(
      PlayHistoryItem(
        shareUrl: prepared.request.shareUrl,
        pageUrl: prepared.request.pageUrl,
        title: prepared.request.title,
        coverUrl: prepared.request.coverUrl ?? '',
        intro: prepared.request.intro ?? '',
        showDirName: prepared.showDirName,
        lastEpisodeFileId: selected.fileId,
        lastEpisodeName: selected.name,
        updatedAtEpochMs: now,
      ),
    );

    return media;
  }

  void _validateShareUrl(String shareUrl) {
    final uri = Uri.tryParse(shareUrl);
    if (uri == null || uri.host != 'pan.quark.cn' || !uri.path.startsWith('/s/')) {
      throw PlaybackException('无效夸克分享链接', code: 'SHARE_URL_INVALID');
    }
  }

  bool _shouldTransfer(List<QuarkFileEntry> files) {
    if (files.isEmpty) return true;
    return !_containsPlayableVideo(files);
  }

  bool _containsPlayableVideo(List<QuarkFileEntry> files) {
    for (final file in files) {
      if (!file.isDirectory && _looksLikeVideo(file.fileName)) {
        return true;
      }
    }
    return false;
  }

  List<EpisodeCandidate> _toEpisodeCandidates(
    List<QuarkFileEntry> files,
    String? preferredFileId,
  ) {
    final episodes = files
        .where((f) => !f.isDirectory && _looksLikeVideo(f.fileName))
        .toList();
    episodes.sort((a, b) => _naturalCompare(a.fileName, b.fileName));
    return episodes
        .map(
          (f) => EpisodeCandidate(
            fileId: f.fileId,
            name: f.fileName,
            selectedByDefault: preferredFileId != null && preferredFileId == f.fileId,
          ),
        )
        .toList();
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
}

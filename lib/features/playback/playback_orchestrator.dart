import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ma_palyer/core/spider/spider_runtime.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/cloud/quark/quark_transfer_service.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';

class PlaybackOrchestrator {
  PlaybackOrchestrator({
    SpiderRuntime? spiderRuntime,
    QuarkAuthService? quarkAuthService,
    QuarkTransferService? quarkTransferService,
    void Function(String message)? logger,
  }) : this._internal(
         spiderRuntime ?? SpiderRuntime(),
         quarkAuthService ?? QuarkAuthService(),
         quarkTransferService,
         logger: logger,
       );

  PlaybackOrchestrator._internal(
    this._spiderRuntime,
    this._quarkAuthService,
    QuarkTransferService? quarkTransferService, {
    this.logger,
  }) : _quarkTransferService =
           quarkTransferService ??
           QuarkTransferService(authService: _quarkAuthService);

  final SpiderRuntime _spiderRuntime;
  final QuarkAuthService _quarkAuthService;
  final QuarkTransferService _quarkTransferService;
  final void Function(String message)? logger;

  Future<PlaybackResolveResult> resolve(
    PlaybackRequest request, {
    Future<QuarkQrSession> Function()? onQuarkLoginRequired,
    String transferRoot = '/MaPlayer',
  }) async {
    final spider = await _spiderRuntime.getSpider(request.sourceKey);
    final vipFlags = await _spiderRuntime.vipFlags();
    final content = await spider.playerContent(
      request.playFlag,
      request.episodeUrl,
      vipFlags,
    );

    final direct = _resolveDirect(content, request);
    if (direct != null) {
      return PlaybackResolveResult(media: direct, rawPlayerContent: content);
    }

    final share = _extractQuarkShare(content);
    if (share == null) {
      throw PlaybackException(
        'Unsupported playerContent payload: missing direct URL and quark share',
        code: 'PLAYER_CONTENT_UNSUPPORTED',
        raw: content,
      );
    }

    await _ensureQuarkLogin(onQuarkLoginRequired);

    final targetDir = '$transferRoot/${_safePathSegment(request.sourceKey)}';
    final saved = await _quarkTransferService.saveShareToMyDrive(
      share,
      targetDir,
    );
    final playable = await _quarkTransferService.resolvePlayableFile(
      saved.fileId,
    );

    final media = PlayableMedia(
      url: playable.url,
      headers: playable.headers,
      subtitle: playable.subtitle,
      progressKey: request.progressKey ?? _defaultProgressKey(request),
    );
    return PlaybackResolveResult(media: media, rawPlayerContent: content);
  }

  Future<void> _ensureQuarkLogin(
    Future<QuarkQrSession> Function()? onQuarkLoginRequired,
  ) async {
    try {
      await _quarkAuthService.ensureValidToken();
    } on QuarkException catch (e) {
      if (e.code != 'AUTH_REQUIRED') rethrow;
      if (onQuarkLoginRequired == null) {
        throw PlaybackException(
          'Quark login required',
          code: 'QUARK_AUTH_REQUIRED',
        );
      }
      final session = await onQuarkLoginRequired();
      final deadline = session.expiresAt;
      while (DateTime.now().isBefore(deadline)) {
        final poll = await _quarkAuthService.pollQrLogin(session.sessionId);
        if (poll.isSuccess) {
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      throw PlaybackException(
        'Quark QR login timeout',
        code: 'QUARK_QR_TIMEOUT',
      );
    }
  }

  PlayableMedia? _resolveDirect(
    Map<String, dynamic> content,
    PlaybackRequest request,
  ) {
    final url = content['url']?.toString() ?? '';
    final playUrl = content['playUrl']?.toString() ?? '';
    if (url.isEmpty) {
      return null;
    }

    final parse = content['parse']?.toString() == '1';
    final jx = content['jx']?.toString() == '1';
    if (parse || jx) {
      return null;
    }

    final subtitle = content['subt']?.toString();
    final headers = _decodeHeaders(content['header']);
    return PlayableMedia(
      url: '$playUrl$url',
      headers: headers,
      subtitle: subtitle,
      progressKey: request.progressKey ?? _defaultProgressKey(request),
    );
  }

  QuarkShareRef? _extractQuarkShare(Map<String, dynamic> content) {
    final quark = content['quark'];
    if (quark is Map) {
      final data = Map<String, dynamic>.from(quark);
      final shareUrl =
          data['shareUrl']?.toString() ?? data['shareRef']?.toString() ?? '';
      if (shareUrl.isNotEmpty) {
        return QuarkShareRef(
          shareUrl: shareUrl,
          fileName: data['name']?.toString(),
        );
      }
    }

    final shareUrl =
        content['quarkShareUrl']?.toString() ??
        content['share_url']?.toString() ??
        '';
    if (shareUrl.isNotEmpty) {
      return QuarkShareRef(
        shareUrl: shareUrl,
        fileName: content['name']?.toString(),
      );
    }
    return null;
  }

  Map<String, String> _decodeHeaders(Object? raw) {
    if (raw == null) return <String, String>{};
    if (raw is Map) {
      return raw.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        }
      } catch (_) {}
    }
    return <String, String>{};
  }

  String _defaultProgressKey(PlaybackRequest request) {
    final bytes = utf8.encode(
      '${request.sourceKey}:${request.playFlag}:${request.episodeUrl}',
    );
    return md5.convert(bytes).toString();
  }

  String _safePathSegment(String input) {
    return input.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }
}

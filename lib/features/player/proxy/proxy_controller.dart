import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';
import 'package:ma_palyer/src/rust/api/proxy_api.dart' as rust;
import 'package:ma_palyer/src/rust/config.dart';
import 'package:path_provider/path_provider.dart';

class ProxyController {
  ProxyController._();

  static final ProxyController instance = ProxyController._();

  static const int _chunkSize = 2 * 1024 * 1024;
  static const int _maxConcurrency = 8;

  bool _engineReady = false;
  String? _activeSessionId;
  Timer? _aggregateStatsTimer;
  StreamController<ProxyAggregateStats>? _aggregateStatsController;
  Future<Map<String, String>?> Function()? _onSourceAuthRejected;

  void _log(String message) => debugPrint('[ProxyController] $message');

  /// Initialize Rust proxy engine as early as possible (app startup).
  Future<void> initialize() async {
    await _ensureEngine();
  }

  Future<void> _ensureEngine() async {
    if (_engineReady) return;
    final cacheDir = await getTemporaryDirectory();
    final proxyCache = Directory('${cacheDir.path}/proxy_cache');
    if (!proxyCache.existsSync()) {
      proxyCache.createSync(recursive: true);
    }
    _log(
      'init engine cacheDir=${proxyCache.path}, chunkSize=$_chunkSize, maxConcurrency=$_maxConcurrency',
    );
    rust.initEngine(
      config: EngineConfig(
        chunkSize: BigInt.from(_chunkSize),
        maxConcurrency: _maxConcurrency,
        cacheDir: proxyCache.path,
      ),
    );
    _engineReady = true;
  }

  Future<ResolvedPlaybackEndpoint> createSession(
    PlayableMedia media, {
    String? fileKey,
    Future<Map<String, String>?> Function()? onSourceAuthRejected,
  }) async {
    if (!_engineReady) {
      _log('engine not ready when creating session, initializing now');
      await _ensureEngine();
    }
    _ensureAggregateTicker();

    if (_isM3u8Like(media.url)) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }

    final shouldProxy =
        (fileKey != null && fileKey.isNotEmpty) || _isMp4Like(media.url);
    if (!shouldProxy) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }

    _onSourceAuthRejected = onSourceAuthRejected;

    _log(
      'create session url=${media.url}, fileKeyPresent=${(fileKey ?? '').isNotEmpty}, headers=${media.headers.length}',
    );
    final info = rust.createSession(
      url: media.url,
      headers: media.headers,
      fileKey: fileKey ?? '',
    );
    _log(
      'session created id=${info.sessionId}, playbackUrl=${info.playbackUrl}, contentLength=${info.contentLength}',
    );

    _activeSessionId = info.sessionId;

    return ResolvedPlaybackEndpoint(
      originalMedia: media,
      playbackUrl: info.playbackUrl,
      proxySession: ProxySessionDescriptor(
        sessionId: info.sessionId,
        sourceUrl: media.url,
        headers: Map<String, String>.from(media.headers),
        mode: ProxyMode.parallel,
        createdAt: DateTime.now(),
        contentLength: info.contentLength.toInt(),
      ),
    );
  }

  Stream<ProxyAggregateStats> watchAggregateStats() {
    _ensureAggregateTicker();
    return _aggregateController().stream;
  }

  Future<void> closeSession(String sessionId) async {
    try {
      rust.closeSession(sessionId: sessionId);
      _log('close session id=$sessionId');
    } catch (e) {
      // Session may already be closed.
      _log('close session ignored id=$sessionId error=$e');
    }
    if (_activeSessionId == sessionId) {
      _activeSessionId = null;
    }
    _emitAggregateSnapshot();
  }

  Future<void> invalidateAll() async {
    _activeSessionId = null;
    try {
      rust.dispose();
      _engineReady = false;
      _log('engine disposed');
    } catch (e) {
      // Engine may not be initialized.
      _log('engine dispose ignored error=$e');
    }
    _emitAggregateSnapshot();
  }

  Future<void> dispose() async {
    _aggregateStatsTimer?.cancel();
    _aggregateStatsTimer = null;
    _aggregateStatsController?.close();
    _aggregateStatsController = null;
    await invalidateAll();
  }

  /// Returns the byte offset of the last known playback position for
  /// [sessionId]. The Rust engine does not track playback position, so
  /// this always returns null — time-based seek from history takes over.
  int? getRestoredPosition(String sessionId) => null;

  /// Called by the player when the Rust proxy encounters an auth rejection.
  /// Refreshes credentials and pushes them back to Rust.
  Future<Map<String, String>?> handleAuthRejected() async {
    final handler = _onSourceAuthRejected;
    if (handler == null) return null;
    final newHeaders = await handler();
    if (newHeaders == null || newHeaders.isEmpty) return null;
    final sid = _activeSessionId;
    if (sid != null) {
      try {
        _log('refresh auth for session=$sid, headers=${newHeaders.length}');
        rust.updateSessionAuth(
          sessionId: sid,
          newUrl: '', // URL unchanged, only headers refresh
          newHeaders: newHeaders,
        );
      } catch (e) {
        // Session may have been closed.
        _log('refresh auth ignored id=$sid error=$e');
      }
    }
    return newHeaders;
  }

  // -- Internal helpers --

  StreamController<ProxyAggregateStats> _aggregateController() {
    final existing = _aggregateStatsController;
    if (existing != null && !existing.isClosed) return existing;
    final created = StreamController<ProxyAggregateStats>.broadcast();
    _aggregateStatsController = created;
    return created;
  }

  void _ensureAggregateTicker() {
    if (_aggregateStatsTimer != null) return;
    _aggregateStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _emitAggregateSnapshot();
    });
  }

  void _emitAggregateSnapshot() {
    final controller = _aggregateController();
    if (controller.isClosed) return;

    if (!_engineReady || _activeSessionId == null) {
      controller.add(
        ProxyAggregateStats(
          proxyRunning: _engineReady,
          downloadBps: 0,
          bufferedBytesAhead: 0,
          activeWorkers: 0,
          updatedAt: DateTime.now(),
        ),
      );
      return;
    }

    try {
      final stats = rust.getStats();
      controller.add(
        ProxyAggregateStats(
          proxyRunning: true,
          downloadBps: stats.downloadBps.toDouble() * 8,
          bufferedBytesAhead: stats.bufferedBytesAhead.toInt(),
          activeWorkers: stats.activeWorkers,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      _log('getStats failed, emitting zero snapshot error=$e');
      controller.add(
        ProxyAggregateStats(
          proxyRunning: _engineReady,
          downloadBps: 0,
          bufferedBytesAhead: 0,
          activeWorkers: 0,
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  bool _isM3u8Like(String url) => url.toLowerCase().contains('.m3u8');

  bool _isMp4Like(String url) => url.toLowerCase().contains('.mp4');
}

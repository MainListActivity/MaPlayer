import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';

class ProxyController {
  ProxyController._();

  static final ProxyController instance = ProxyController._();

  static const int _chunkSize = 2 * 1024 * 1024;
  static const int _maxConcurrency = 8;
  static const int _sessionCacheWindowBytes = 1024 * 1024 * 1024;
  static const int _priorityBufferSeconds = 120;
  static const int _maxOpenEndedResponseBytes = 64 * 1024 * 1024;
  static const int _startupProbeOpenEndedResponseBytes = 2 * 1024 * 1024;

  final Map<String, _ProxySession> _sessions = <String, _ProxySession>{};
  StreamController<ProxyAggregateStats>? _aggregateStatsController;
  LocalStreamProxyServer? _server;
  Timer? _aggregateStatsTimer;
  int _aggregateDownloadedBytesTotal = 0;
  int _aggregateDownloadedBytesLast = 0;
  DateTime _aggregateStatsLastAt = DateTime.now();

  bool get _isSupportedPlatform => Platform.isMacOS || Platform.isWindows;

  // Test-only knobs to shrink prefetch/cache windows for fast unit tests.
  static int? debugSessionCacheWindowBytesOverride;
  static int? debugPriorityBufferSecondsOverride;

  Future<ResolvedPlaybackEndpoint> createSession(
    PlayableMedia media, {
    String? fileKey,
  }) async {
    if (!_isSupportedPlatform) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }
    _server ??= LocalStreamProxyServer(
      onStreamRequest: _handleStreamRequest,
      logger: _log,
    );
    await _server!.start();
    _ensureAggregateTicker();

    if (_isM3u8Like(media.url)) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }
    // Route through the proxy when fileKey is provided (identified cloud file)
    // or when the URL looks like an mp4. Plain API endpoint URLs without a
    // file extension (e.g. Quark raw-download URLs) are caught by the fileKey
    // branch so they are proxied rather than streamed directly to media_kit.
    final shouldProxy =
        (fileKey != null && fileKey.isNotEmpty) || _isMp4Like(media.url);
    if (!shouldProxy) {
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: media.url,
      );
    }

    final sessionId = _sessionIdFor(media.url, media.headers, fileKey: fileKey);
    final existing = _sessions[sessionId];
    if (existing != null) {
      existing.touch();
      return ResolvedPlaybackEndpoint(
        originalMedia: media,
        playbackUrl: _server!.urlForSession(sessionId),
        proxySession: existing.descriptor,
      );
    }

    // Cancel any other active sessions — only one download task at a time.
    final staleIds = _sessions.keys.where((id) => id != sessionId).toList();
    for (final staleId in staleIds) {
      final stale = _sessions.remove(staleId);
      if (stale != null) {
        unawaited(stale.dispose());
      }
    }

    final createdAt = DateTime.now();
    final session = _ProxySession(
      sessionId: sessionId,
      sourceUrl: media.url,
      headers: media.headers,
      createdAt: createdAt,
      streamUrl: _server!.urlForSession(sessionId),
      logger: _log,
      onDownloadBytes: _recordAggregateDownloadedBytes,
      chunkSize: _chunkSize,
      maxConcurrency: _maxConcurrency,
      sessionCacheWindowBytes:
          debugSessionCacheWindowBytesOverride ?? _sessionCacheWindowBytes,
      priorityBufferSeconds:
          debugPriorityBufferSecondsOverride ?? _priorityBufferSeconds,
      maxOpenEndedResponseBytes: _maxOpenEndedResponseBytes,
      startupProbeOpenEndedResponseBytes: _startupProbeOpenEndedResponseBytes,
    );
    await session.initialize();
    _sessions[sessionId] = session;
    _emitAggregateSnapshot();

    return ResolvedPlaybackEndpoint(
      originalMedia: media,
      playbackUrl: _server!.urlForSession(sessionId),
      proxySession: session.descriptor,
    );
  }

  Map<String, dynamic>? debugSessionSnapshot(String sessionId) {
    return _sessions[sessionId]?.debugSnapshot();
  }

  Stream<ProxyStatsSnapshot> watchStats(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      return const Stream<ProxyStatsSnapshot>.empty();
    }
    return session.statsStream;
  }

  /// Returns the byte offset of the last known playback position for
  /// [sessionId], or null if no position has been saved.
  int? getRestoredPosition(String sessionId) =>
      _sessions[sessionId]?.restoredPlaybackPosition;

  Stream<ProxyAggregateStats> watchAggregateStats() {
    _ensureAggregateTicker();
    _emitAggregateSnapshot();
    return _aggregateController().stream;
  }

  Future<void> closeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session != null) {
      await session.dispose();
      _emitAggregateSnapshot();
    }
  }

  Future<void> invalidateAll() async {
    final entries = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in entries) {
      await session.dispose();
    }
    _emitAggregateSnapshot();
  }

  Future<void> dispose() async {
    await invalidateAll();
    _aggregateStatsTimer?.cancel();
    _aggregateStatsTimer = null;
    await _server?.stop();
    _server = null;
  }

  StreamController<ProxyAggregateStats> _aggregateController() {
    final existing = _aggregateStatsController;
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    final created = StreamController<ProxyAggregateStats>.broadcast();
    _aggregateStatsController = created;
    return created;
  }

  void _ensureAggregateTicker() {
    if (_aggregateStatsTimer != null) return;
    _aggregateStatsLastAt = DateTime.now();
    _aggregateDownloadedBytesLast = _aggregateDownloadedBytesTotal;
    _aggregateStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _emitAggregateSnapshot();
    });
  }

  void _recordAggregateDownloadedBytes(int bytes) {
    if (bytes <= 0) return;
    _aggregateDownloadedBytesTotal += bytes;
  }

  void _emitAggregateSnapshot() {
    final controller = _aggregateController();
    if (controller.isClosed) return;
    final now = DateTime.now();
    final elapsedMs = max(
      1,
      now.difference(_aggregateStatsLastAt).inMilliseconds,
    );
    final downloadDelta =
        _aggregateDownloadedBytesTotal - _aggregateDownloadedBytesLast;
    final downloadBps = downloadDelta * 8000.0 / elapsedMs;
    _aggregateStatsLastAt = now;
    _aggregateDownloadedBytesLast = _aggregateDownloadedBytesTotal;
    var bufferedBytesAhead = 0;
    var activeWorkers = 0;
    for (final session in _sessions.values) {
      final latest = session.latestSnapshot;
      bufferedBytesAhead += latest.bufferedBytesAhead;
      activeWorkers += latest.activeWorkers;
    }
    controller.add(
      ProxyAggregateStats(
        proxyRunning: _server != null,
        downloadBps: downloadBps,
        bufferedBytesAhead: bufferedBytesAhead,
        activeWorkers: activeWorkers,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _handleStreamRequest(
    HttpRequest request,
    String sessionId,
  ) async {
    final session = _sessions[sessionId];
    final path = request.uri.path;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader) ?? '';
    final cachedRanges = session?.debugSnapshot()['cachedRanges'];

    _log(
      'incoming request: method=${request.method} path=$path '
      'range=$rangeHeader cachedRanges=$cachedRanges',
    );

    if (session == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('session not found');
      await request.response.close();
      return;
    }
    session.touch();
    await session.handleRequest(request);
  }

  String _sessionIdFor(
    String sourceUrl,
    Map<String, String> headers, {
    String? fileKey,
  }) {
    // Prefer the stable cloud-file identity when available, so signed/raw
    // URLs that rotate query tokens still reuse the same disk cache.
    final buffer = StringBuffer();
    if (fileKey != null && fileKey.isNotEmpty) {
      buffer.write('file:');
      buffer.write(fileKey);
    } else {
      buffer.write('url:');
      buffer.write(sourceUrl);
    }
    return md5.convert(utf8.encode(buffer.toString())).toString();
  }

  void _log(String message) {
    // ignore: avoid_print
    print('[proxy] $message');
  }

  bool _isM3u8Like(String url) {
    return url.toLowerCase().contains('.m3u8');
  }

  bool _isMp4Like(String url) {
    return url.toLowerCase().contains('.mp4');
  }
}

class LocalStreamProxyServer {
  LocalStreamProxyServer({required this.onStreamRequest, required this.logger});

  final Future<void> Function(HttpRequest request, String sessionId)
  onStreamRequest;
  final void Function(String message) logger;

  HttpServer? _server;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      unawaited(_handle(request));
    });
    logger(
      'local proxy started at ${_server!.address.address}:${_server!.port}',
    );
  }

  String urlForSession(String sessionId) {
    final server = _server;
    if (server == null) {
      throw StateError('proxy server not started');
    }
    return 'http://${server.address.address}:${server.port}/stream/$sessionId';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('not found');
      await request.response.close();
      return;
    }
    if (path.startsWith('/stream/')) {
      final sessionId = path.substring('/stream/'.length).trim();
      if (sessionId.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('invalid session id');
        await request.response.close();
        return;
      }
      await onStreamRequest(request, sessionId);
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    request.response.write('not found');
    await request.response.close();
  }
}

class _ProxySession {
  _ProxySession({
    required this.sessionId,
    required this.sourceUrl,
    required this.headers,
    required this.createdAt,
    required this.streamUrl,
    required this.logger,
    required this.onDownloadBytes,
    required this.chunkSize,
    required this.maxConcurrency,
    required this.sessionCacheWindowBytes,
    required this.priorityBufferSeconds,
    required this.maxOpenEndedResponseBytes,
    required this.startupProbeOpenEndedResponseBytes,
  }) : _client = HttpClient(),
       _semaphore = _AsyncSemaphore(maxConcurrency);

  final String sessionId;
  final String sourceUrl;
  final Map<String, String> headers;
  final DateTime createdAt;
  final String streamUrl;
  final void Function(String message) logger;
  final void Function(int bytes) onDownloadBytes;
  final int chunkSize;
  final int maxConcurrency;
  final int sessionCacheWindowBytes;
  final int priorityBufferSeconds;
  final int maxOpenEndedResponseBytes;
  final int startupProbeOpenEndedResponseBytes;
  static const bool _verboseUpstreamHeaderLogs = false;
  static const int _memoryCacheLimitBytes = 1024 * 1024 * 1024;

  final HttpClient _client;
  final _AsyncSemaphore _semaphore;
  final StreamController<ProxyStatsSnapshot> _statsController =
      StreamController<ProxyStatsSnapshot>.broadcast();
  final Map<int, Completer<bool>> _inFlight = <int, Completer<bool>>{};
  late final _RangeMemoryCache _memoryCache;

  Timer? _statsTimer;
  bool _isDisposing = false;
  bool _isDisposed = false;

  ProxyMode _mode = ProxyMode.parallel;
  String? _degradeReason;
  int? _contentLength;

  int _activeWorkers = 0;
  int _playbackOffset = 0;
  int? _lastPlaybackPosition;
  int _cacheWindowAnchor = 0;
  int _cacheWindowStart = 0;
  int _cacheWindowEnd = 0;
  DateTime? _lastPlaybackSampleAt;
  int? _lastPlaybackSampleOffset;
  double _playbackBytesPerSecond = 1.5 * 1024 * 1024; // 12 Mbps default
  static const int _seekThresholdBytes = 4 * 1024 * 1024; // 4 MB
  static const Duration _seekDetectionWarmup = Duration(seconds: 3);
  static const int _seekDetectionWarmupRequests = 3;
  static const int _seekStableSequentialHits = 2;
  static const int _probeHeadBytes = 2 * 1024 * 1024;
  static const int _probeTailBytes = 16 * 1024 * 1024;
  final Set<int> _abortedChunks = <int>{};
  final Set<int> _ignoreWindowChunks = <int>{};
  DateTime? _firstParallelRequestAt;
  int _parallelRequestCount = 0;
  int? _lastRequestStartForSeek;
  int? _lastRequestEndForSeek;
  int _stableSequentialHits = 0;
  bool _seekDetectionEnabled = false;

  int _downloadBytesTotal = 0;
  int _serveBytesTotal = 0;
  int _downloadBytesLastSample = 0;
  int _serveBytesLastSample = 0;
  DateTime _statsLastSampleAt = DateTime.now();
  int _requestedBytes = 0;
  int _cacheHitBytes = 0;

  String? _contentType;
  late ProxyStatsSnapshot _latestSnapshot;

  Stream<ProxyStatsSnapshot> get statsStream => _statsController.stream;
  ProxyStatsSnapshot get latestSnapshot => _latestSnapshot;

  ProxySessionDescriptor get descriptor => ProxySessionDescriptor(
    sessionId: sessionId,
    sourceUrl: sourceUrl,
    headers: headers,
    mode: _mode,
    createdAt: createdAt,
    contentLength: _contentLength,
  );

  int? get restoredPlaybackPosition => _lastPlaybackPosition;

  Map<String, dynamic> debugSnapshot() {
    return <String, dynamic>{
      'mode': _mode.name,
      'degradeReason': _degradeReason,
      'contentLength': _contentLength,
      'cacheWindowAnchor': _cacheWindowAnchor,
      'cacheWindowStart': _cacheWindowStart,
      'cacheWindowEnd': _cacheWindowEnd,
      'cachedChunkCount': _memoryCache.chunkCount,
      'cachedBytes': _memoryCache.currentBytes,
      'cachedRanges': _memoryCache.cachedRanges
          .map((e) => <String, int>{'start': e.start, 'end': e.end})
          .toList(growable: false),
      'lastPlaybackPosition': _lastPlaybackPosition ?? _playbackOffset,
    };
  }

  Future<void> initialize() async {
    _memoryCache = _RangeMemoryCache(
      chunkSize: chunkSize,
      maxBytes: _memoryCacheLimitBytes,
    );

    final probe = await _probeRangeSupport();
    _contentLength = probe.contentLength;
    _contentType = probe.contentType;
    _updateCacheWindow(0);
    _preloadHeadAndTail();

    if (!probe.supportsRange ||
        _contentLength == null ||
        _contentLength! <= 0) {
      _degradeToSingle(
        'range unsupported or unknown content length '
        '(supportsRange=${probe.supportsRange}, len=${probe.contentLength})',
      );
    }
    _statsLastSampleAt = DateTime.now();
    _downloadBytesLastSample = _downloadBytesTotal;
    _serveBytesLastSample = _serveBytesTotal;
    _latestSnapshot = ProxyStatsSnapshot(
      sessionId: sessionId,
      downloadBps: 0,
      serveBps: 0,
      cacheHitRate: 0,
      activeWorkers: _activeWorkers,
      bufferedBytesAhead: _bufferedBytesAhead(),
      mode: _mode,
      updatedAt: DateTime.now(),
    );

    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_statsController.isClosed) return;
      final now = DateTime.now();
      final elapsedMs = max(
        1,
        now.difference(_statsLastSampleAt).inMilliseconds,
      );
      final downloadDelta = _downloadBytesTotal - _downloadBytesLastSample;
      final serveDelta = _serveBytesTotal - _serveBytesLastSample;
      final snapshot = ProxyStatsSnapshot(
        sessionId: sessionId,
        downloadBps: downloadDelta * 8000.0 / elapsedMs,
        serveBps: serveDelta * 8000.0 / elapsedMs,
        cacheHitRate: _requestedBytes <= 0
            ? 0
            : _cacheHitBytes / _requestedBytes,
        activeWorkers: _activeWorkers,
        bufferedBytesAhead: _bufferedBytesAhead(),
        mode: _mode,
        updatedAt: now,
      );
      _statsLastSampleAt = now;
      _downloadBytesLastSample = _downloadBytesTotal;
      _serveBytesLastSample = _serveBytesTotal;
      _latestSnapshot = snapshot;
      if (!_statsController.isClosed) {
        _statsController.add(snapshot);
      }
    });
  }

  void touch() {
    // Intentionally no-op; kept for API symmetry and future instrumentation.
  }

  Future<void> handleRequest(HttpRequest request) async {
    if (_isDisposing || _isDisposed) {
      request.response.statusCode = HttpStatus.gone;
      request.response.write('session disposed');
      await request.response.close();
      return;
    }
    try {
      final parsedRange = _parseRangeHeader(
        request.headers.value(HttpHeaders.rangeHeader),
      );
      if (request.method == 'HEAD') {
        await _serveHead(request, parsedRange);
        return;
      }
      if (_mode == ProxyMode.single) {
        await _serveSingle(request, parsedRange);
        return;
      }
      await _serveParallel(request, parsedRange);
    } catch (e, st) {
      if (_isDisposing || _isDisposed || _isClientClosedError(e)) {
        try {
          request.response.statusCode = HttpStatus.gone;
          await request.response.close();
        } catch (_) {
          // Best-effort close for cancelled requests.
        }
        return;
      }
      logger('session=$sessionId handle request failed: $e\n$st');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('proxy failed: $e');
      } catch (_) {
        // Response might already be committed.
      }
      try {
        await request.response.close();
      } catch (_) {
        // Ignore close errors.
      }
    }
  }

  Future<void> dispose() async {
    if (_isDisposed || _isDisposing) return;
    _isDisposing = true;
    _statsTimer?.cancel();
    final inflight = _inFlight.values.toList(growable: false);
    if (inflight.isNotEmpty) {
      await Future.wait(
        inflight.map((c) => c.future.then((_) {}, onError: (_) {})),
      );
    }
    _client.close(force: true);
    await _statsController.close();

    _memoryCache.clear();

    _isDisposed = true;
    _isDisposing = false;
  }

  Future<void> _serveSingle(HttpRequest request, _RequestRange? range) async {
    if (_isDisposing || _isDisposed) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    final uri = Uri.parse(sourceUrl);
    final upstreamRequest = await _client.getUrl(uri);
    _applyHeaders(upstreamRequest.headers, headers);

    final upstreamRange = _rangeHeaderValue(range);
    if (upstreamRange != null) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, upstreamRange);
    }
    _logUpstreamRequestHeaders('serveSingle', upstreamRequest.headers);

    final upstreamResponse = await upstreamRequest.close();
    request.response.statusCode = upstreamResponse.statusCode;
    _copyResponseHeaders(upstreamResponse.headers, request.response.headers);
    var offset = range?.start ?? 0;

    await for (final chunk in upstreamResponse) {
      _recordDownloadedBytes(chunk.length);
      _recordServedBytes(chunk.length);
      request.response.add(chunk);
      offset += chunk.length;
      _playbackOffset = offset;
      _lastPlaybackPosition = offset;
    }
    await request.response.close();
  }

  /// Continues an already-started response by streaming the remaining bytes
  /// from upstream. Must not touch status code or response headers.
  Future<void> _serveSingleTail(
    HttpRequest request,
    _RequestRange requested,
  ) async {
    final uri = Uri.parse(sourceUrl);
    final upstreamRequest = await _client.getUrl(uri);
    _applyHeaders(upstreamRequest.headers, headers);
    upstreamRequest.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${requested.start}-${requested.end!}',
    );
    _logUpstreamRequestHeaders('serveSingleTail', upstreamRequest.headers);

    final upstreamResponse = await upstreamRequest.close();
    var offset = requested.start;
    await for (final chunk in upstreamResponse) {
      _recordDownloadedBytes(chunk.length);
      _recordServedBytes(chunk.length);
      request.response.add(chunk);
      offset += chunk.length;
      _playbackOffset = offset;
      _lastPlaybackPosition = offset;
    }
    await request.response.close();
  }

  Future<void> _serveHead(HttpRequest request, _RequestRange? range) async {
    final length = _contentLength;
    final contentType = _contentType ?? 'video/mp4';
    if (length == null || length <= 0) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      await request.response.close();
      return;
    }

    var requested = _normalizeRequestedRange(
      range,
      length,
      maxOpenEndedBytes: maxOpenEndedResponseBytes,
    );
    if (requested == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$length',
      );
      await request.response.close();
      return;
    }

    final partial = !(requested.start == 0 && requested.end == length - 1);
    request.response.statusCode = partial
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${requested.end! - requested.start + 1}',
    );
    if (partial) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${requested.start}-${requested.end!}/$length',
      );
    }
    await request.response.close();
  }

  Future<void> _serveParallel(HttpRequest request, _RequestRange? range) async {
    final length = _contentLength;
    if (length == null || length <= 0) {
      _degradeToSingle('content length invalid in parallel mode');
      await _serveSingle(request, range);
      return;
    }

    var requested = _normalizeRequestedRange(
      range,
      length,
      maxOpenEndedBytes: maxOpenEndedResponseBytes,
    );
    if (requested == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$length',
      );
      await request.response.close();
      return;
    }

    final previousOffset = _playbackOffset;
    final previousRequestStart = _lastRequestStartForSeek;
    final previousRequestEnd = _lastRequestEndForSeek;

    // Detect seek only after startup warmup and stable sequential playback.
    var isSeek = false;
    final openEndedRequested = range?.end == null;
    final seekBaseline = previousRequestStart ?? previousOffset;
    final probeJump = _isLikelyProbeJump(seekBaseline, requested.start, length);
    final startupProbeJump = probeJump && !_seekDetectionEnabled;
    if (startupProbeJump && openEndedRequested) {
      final clampedEnd = min(
        length - 1,
        requested.start + startupProbeOpenEndedResponseBytes - 1,
      );
      if (clampedEnd < requested.end!) {
        requested = _RequestRange(start: requested.start, end: clampedEnd);
        logger(
          'session=$sessionId startup probe clamp: '
          'start=${requested.start}, end=${requested.end}',
        );
      }
    }
    _updateSeekDetectionState(requested.start, requested.end!);
    _updatePlaybackRate(requested.start);
    if (!startupProbeJump) {
      _updateCacheWindow(requested.start);
    } else {
      logger(
        'session=$sessionId startup probe jump: keep cache window '
        'at anchor=$_cacheWindowAnchor, requestStart=${requested.start}',
      );
    }
    final jump = (requested.start - seekBaseline).abs();
    final overlapsPreviousRequest =
        previousRequestStart != null &&
        previousRequestEnd != null &&
        requested.start >= previousRequestStart &&
        requested.start <= previousRequestEnd;
    final sequentialToPreviousRequest =
        previousRequestEnd != null && requested.start == previousRequestEnd + 1;
    final jumpLooksLikeSeek =
        requested.start > 0 &&
        seekBaseline > 0 &&
        jump > _seekThresholdBytes &&
        !overlapsPreviousRequest &&
        !sequentialToPreviousRequest;
    if (jumpLooksLikeSeek && _seekDetectionEnabled) {
      if (probeJump) {
        logger(
          'session=$sessionId probe jump ignored: '
          'from=$seekBaseline to=${requested.start}',
        );
      } else {
        isSeek = true;
      }
    } else if (jumpLooksLikeSeek && !_seekDetectionEnabled) {
      logger(
        'session=$sessionId jump ignored before seek detection ready: '
        'from=$seekBaseline to=${requested.start}',
      );
    }
    if (isSeek) {
      logger(
        'session=$sessionId seek detected: '
        'from=$seekBaseline to=${requested.start}, '
        'aborting out-of-window prefetch tasks',
      );
      _abortOutOfWindowChunks();
    }
    _playbackOffset = requested.start;

    if (isSeek) {
      _ensureRangeAvailableBackground(requested.start);
    }

    final requestedBytes = requested.end! - requested.start + 1;
    _requestedBytes += requestedBytes;
    _cacheHitBytes += _countCachedBytesInRange(requested.start, requested.end!);

    final startupEnd = min(
      requested.end!,
      requested.start + max(chunkSize, 512 * 1024).toInt() - 1,
    );
    await _ensureRangeAvailable(requested.start, startupEnd);
    if (_mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }

    final firstChunkReady = await _ensureChunkReady(
      requested.start ~/ chunkSize,
    );
    if (!firstChunkReady || _mode == ProxyMode.single) {
      await _serveSingle(request, requested);
      return;
    }

    final statusCode =
        (requested.start == 0 && requested.end == length - 1 && range == null)
        ? HttpStatus.ok
        : HttpStatus.partialContent;

    request.response.statusCode = statusCode;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentType ?? 'video/mp4',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${requested.end! - requested.start + 1}',
    );
    if (statusCode == HttpStatus.partialContent) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${requested.start}-${requested.end!}/$length',
      );
    }

    var degraded = false;
    var offset = requested.start;
    final end = requested.end!;
    while (offset <= end) {
      final chunkIndex = offset ~/ chunkSize;
      var chunkData = _memoryCache.peekChunk(chunkIndex);
      if (chunkData == null) {
        _startPrefetch(chunkIndex);
        final chunkReady = await _ensureChunkReady(chunkIndex);
        if (!chunkReady || _mode == ProxyMode.single) {
          if (!_isChunkInsideCacheWindow(chunkIndex)) {
            logger(
              'session=$sessionId chunk $chunkIndex not ready because it is outside cache window (likely aborted by seek)',
            );
          } else {
            _degradeToSingle('chunk $chunkIndex not ready during serve');
          }
          degraded = true;
          break;
        }
        chunkData = _memoryCache.peekChunk(chunkIndex);
      }
      if (chunkData == null || chunkData.isEmpty) {
        _degradeToSingle('chunk $chunkIndex missing after ready');
        degraded = true;
        break;
      }
      _touchChunk(chunkIndex);
      final chunkStart = chunkIndex * chunkSize;
      final localOffset = offset - chunkStart;
      if (localOffset < 0 || localOffset >= chunkData.length) {
        _degradeToSingle(
          'invalid localOffset=$localOffset for chunk=$chunkIndex len=${chunkData.length}',
        );
        degraded = true;
        break;
      }
      final remaining = end - offset + 1;
      final readLen = min(
        remaining,
        min(64 * 1024, chunkData.length - localOffset),
      );
      final data = Uint8List.sublistView(
        chunkData,
        localOffset,
        localOffset + readLen,
      );
      _recordServedBytes(data.length);
      request.response.add(data);
      offset += data.length;
      _playbackOffset = offset;
      _lastPlaybackPosition = offset;
    }
    if (degraded) {
      await _serveSingleTail(
        request,
        _RequestRange(start: offset, end: requested.end),
      );
      return;
    }
    await request.response.close();
  }

  Future<void> _ensureRangeAvailable(int start, int end) async {
    final length = _contentLength;
    if (length == null || length <= 0) return;

    final needStartChunk = start ~/ chunkSize;
    final needEndChunk = end ~/ chunkSize;
    final priorityEnd = _priorityWindowEnd(start, length);
    final priorityStartChunk = start ~/ chunkSize;
    final priorityEndChunk = priorityEnd ~/ chunkSize;

    // Stage 1: prioritize current position to ~2 minutes ahead.
    for (var i = priorityStartChunk; i <= priorityEndChunk; i++) {
      _startPrefetch(i);
    }
    // Stage 2: then fill the remaining cache window (up to anchor + 500 MB).
    final windowStartChunk = _cacheWindowStart ~/ chunkSize;
    final windowEndChunk = _cacheWindowEnd ~/ chunkSize;
    for (var i = windowStartChunk; i <= windowEndChunk; i++) {
      if (i >= priorityStartChunk && i <= priorityEndChunk) continue;
      _startPrefetch(i);
    }

    // Wait for the chunks that are required for the current request.
    for (var i = needStartChunk; i <= needEndChunk; i++) {
      final ok = await _waitForChunk(i);
      if (!ok || _mode == ProxyMode.single) return;
    }
  }

  /// Kicks off background prefetch for the window around [start] without
  /// waiting for any chunk to complete.
  void _ensureRangeAvailableBackground(int start) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    _updateCacheWindow(start);
    final priorityEnd = _priorityWindowEnd(start, length);
    final priorityStartChunk = start ~/ chunkSize;
    final priorityEndChunk = priorityEnd ~/ chunkSize;
    for (var i = priorityStartChunk; i <= priorityEndChunk; i++) {
      _startPrefetch(i);
    }
    final windowStartChunk = _cacheWindowStart ~/ chunkSize;
    final windowEndChunk = _cacheWindowEnd ~/ chunkSize;
    for (var i = windowStartChunk; i <= windowEndChunk; i++) {
      if (i >= priorityStartChunk && i <= priorityEndChunk) continue;
      _startPrefetch(i);
    }
  }

  int _countCachedBytesInRange(int start, int end) {
    final length = _contentLength;
    if (length == null || length <= 0) return 0;
    return _memoryCache.countCachedBytesInRange(start, end, length);
  }

  int _priorityWindowEnd(int start, int length) {
    final minPriorityBytes = min(32 * 1024 * 1024, sessionCacheWindowBytes);
    final targetBytes = (_playbackBytesPerSecond * priorityBufferSeconds)
        .round()
        .clamp(minPriorityBytes, sessionCacheWindowBytes);
    return min(length - 1, start + targetBytes - 1);
  }

  void _updatePlaybackRate(int newStart) {
    final now = DateTime.now();
    final prevAt = _lastPlaybackSampleAt;
    final prevOffset = _lastPlaybackSampleOffset;
    _lastPlaybackSampleAt = now;
    _lastPlaybackSampleOffset = newStart;
    if (prevAt == null || prevOffset == null) return;
    final dt = now.difference(prevAt).inMilliseconds;
    if (dt <= 0) return;
    final deltaBytes = newStart - prevOffset;
    // Ignore backwards jumps and very large jumps from startup probing/seek.
    if (deltaBytes <= 0 || deltaBytes > _seekThresholdBytes) return;
    if (deltaBytes < 64 * 1024) return;
    final instant = deltaBytes * 1000.0 / dt;
    // EWMA for stability so short request jitters don't swing window size.
    _playbackBytesPerSecond =
        (_playbackBytesPerSecond * 0.75) + (instant * 0.25);
    _playbackBytesPerSecond = _playbackBytesPerSecond.clamp(
      256 * 1024,
      8 * 1024 * 1024,
    );
  }

  void _updateSeekDetectionState(int requestedStart, int requestedEnd) {
    final now = DateTime.now();
    _firstParallelRequestAt ??= now;
    _parallelRequestCount += 1;

    final previousStart = _lastRequestStartForSeek;
    final previousEnd = _lastRequestEndForSeek;
    if (previousStart != null) {
      final delta = requestedStart - previousStart;
      final overlapsPrevious =
          previousEnd != null &&
          requestedStart >= previousStart &&
          requestedStart <= previousEnd;
      final sequentialToPrevious =
          previousEnd != null && requestedStart == previousEnd + 1;
      if (overlapsPrevious || sequentialToPrevious) {
        _stableSequentialHits += 1;
      } else if (delta >= 0 && delta <= _seekThresholdBytes) {
        _stableSequentialHits += 1;
      } else if (delta.abs() <= 128 * 1024) {
        // Nearby duplicate request, keep current streak.
      } else {
        _stableSequentialHits = 0;
      }
    }
    _lastRequestStartForSeek = requestedStart;
    _lastRequestEndForSeek = requestedEnd;

    if (_seekDetectionEnabled) return;
    final firstAt = _firstParallelRequestAt;
    if (firstAt == null) return;
    final warmedUp = now.difference(firstAt) >= _seekDetectionWarmup;
    final enoughRequests = _parallelRequestCount > _seekDetectionWarmupRequests;
    final stablePlayback = _stableSequentialHits >= _seekStableSequentialHits;
    if (warmedUp && enoughRequests && stablePlayback) {
      _seekDetectionEnabled = true;
      logger(
        'session=$sessionId seek detection enabled: '
        'requests=$_parallelRequestCount, stableHits=$_stableSequentialHits',
      );
    }
  }

  bool _isLikelyProbeJump(int from, int to, int length) {
    if (length <= 0) return false;
    final headLimit = min(length - 1, max(chunkSize, _probeHeadBytes));
    final tailStart = max(0, length - max(_probeTailBytes, chunkSize * 4));
    // For short files, head/tail probe zones overlap; don't classify as probe.
    if (tailStart <= headLimit) return false;
    final fromHead = from <= headLimit;
    final toTail = to >= tailStart;
    return fromHead && toTail;
  }

  void _updateCacheWindow(int anchorStart) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    _cacheWindowAnchor = anchorStart.clamp(0, max(0, length - 1));
    _cacheWindowStart = _cacheWindowAnchor;
    _cacheWindowEnd = min(
      length - 1,
      _cacheWindowAnchor + sessionCacheWindowBytes - 1,
    );
    _evictChunksIfNeeded();
    _abortOutOfWindowChunks();
  }

  void _touchChunk(int chunkIndex) {
    _memoryCache.touchChunk(chunkIndex);
  }

  bool _isChunkInsideCacheWindow(int chunkIndex) {
    final length = _contentLength;
    if (length == null || length <= 0) return false;
    final chunkStart = chunkIndex * chunkSize;
    if (chunkStart >= length) return false;
    final chunkEnd = min(length - 1, chunkStart + chunkSize - 1);
    return chunkEnd >= _cacheWindowStart && chunkStart <= _cacheWindowEnd;
  }

  void _evictChunksIfNeeded() {
    // 移除原有导致强制驱除窗外 Chunk 的代码。
    // 播放器可能有跳跃式探测的行为。
    // 我们将缓存数据的清理职责完全交给基于 maxBytes 的 LRU 淘汰机制。
    while (_memoryCache.currentBytes > _memoryCache.maxBytes) {
      final oldest = _memoryCache.oldestChunkIndex;
      if (oldest == null) break;
      _memoryCache.removeChunk(oldest);
    }
  }

  /// Downloads a chunk from the network and returns the received data.
  /// Returns null on failure (after retries).
  Future<Uint8List?> _downloadChunk(int chunkIndex) async {
    final length = _contentLength;
    if (length == null || length <= 0) return null;

    final start = chunkIndex * chunkSize;
    if (start >= length) return Uint8List(0);
    final end = min(length - 1, start + chunkSize - 1);
    final expectedBytes = end - start + 1;

    for (var retry = 0; retry < 3; retry++) {
      try {
        final uri = Uri.parse(sourceUrl);
        final req = await _client.getUrl(uri);
        _applyHeaders(req.headers, headers);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
        _logUpstreamRequestHeaders('downloadChunk($chunkIndex)', req.headers);

        final resp = await req.close();
        if (resp.statusCode == HttpStatus.partialContent) {
          var received = 0;
          final builder = BytesBuilder(copy: false);
          await for (final data in resp) {
            _recordDownloadedBytes(data.length);
            received += data.length;
            builder.add(data);
          }
          if (received == expectedBytes) {
            return builder.takeBytes();
          }
          if (retry == 2) {
            _degradeToSingle(
              'chunk incomplete: idx=$chunkIndex received=$received expected=$expectedBytes',
            );
            return null;
          }
          continue;
        }

        if (resp.statusCode == HttpStatus.forbidden ||
            resp.statusCode == HttpStatus.unauthorized) {
          _degradeToSingle('source auth rejected during range chunk');
          return null;
        }

        _degradeToSingle('source returned status=${resp.statusCode} for range');
        return null;
      } catch (_) {
        if (retry == 2) {
          _degradeToSingle('chunk download failed after retries');
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * (retry + 1)));
      }
    }
    return null;
  }

  /// Marks all in-flight chunks outside the new prefetch window as aborted.
  /// Aborted tasks check [_abortedChunks] at key points and exit early,
  /// releasing their semaphore slot immediately.
  void _abortOutOfWindowChunks() {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    final windowStartChunk = _cacheWindowStart ~/ chunkSize;
    final windowEndChunk = _cacheWindowEnd ~/ chunkSize;
    // Clear stale abort markers so previously-aborted chunks that fall back
    // inside the new window are not permanently blacklisted.
    _abortedChunks.clear();
    for (final idx in _inFlight.keys.toList()) {
      if (!_ignoreWindowChunks.contains(idx)) {
        if (idx < windowStartChunk || idx > windowEndChunk) {
          _abortedChunks.add(idx);
        }
      }
    }
  }

  void _preloadHeadAndTail() {
    final length = _contentLength;
    if (length == null || length <= 0) return;

    // Preload head
    _startPrefetch(0, ignoreWindow: true);

    // Preload tail
    final tailChunkIndex = (length - 1) ~/ chunkSize;
    if (tailChunkIndex > 0) {
      _startPrefetch(tailChunkIndex, ignoreWindow: true);
    }

    logger(
      'session=$sessionId started preload for head (chunk 0) and tail (chunk $tailChunkIndex)',
    );
  }

  /// Starts a chunk download in the background. Does not wait for completion.
  /// Idempotent: no-op if the chunk is already downloaded or already in-flight.
  void _startPrefetch(int chunkIndex, {bool ignoreWindow = false}) {
    if (_mode == ProxyMode.single) return;
    final length = _contentLength;
    if (length == null || length <= 0) return;
    if (chunkIndex < 0 || chunkIndex * chunkSize >= length) return;
    if (!ignoreWindow && !_isChunkInsideCacheWindow(chunkIndex)) return;
    if (_memoryCache.containsChunk(chunkIndex)) return;
    if (_inFlight.containsKey(chunkIndex)) return;

    final completer = Completer<bool>();
    _inFlight[chunkIndex] = completer;
    if (ignoreWindow) {
      _ignoreWindowChunks.add(chunkIndex);
    }

    unawaited(() async {
      await _semaphore.acquire();
      _activeWorkers += 1;
      try {
        // Checkpoint 1: abort before doing any work (seek cleared this slot).
        if (!ignoreWindow && _abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (!ignoreWindow && !_isChunkInsideCacheWindow(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (_memoryCache.containsChunk(chunkIndex)) {
          completer.complete(true);
          return;
        }
        if (_mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        final data = await _downloadChunk(chunkIndex);
        // Checkpoint 2: abort after download completes (seek happened mid-download).
        if (!ignoreWindow && _abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (!ignoreWindow && !_isChunkInsideCacheWindow(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (data == null || _mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        _memoryCache.putChunk(chunkIndex, data);
        _touchChunk(chunkIndex);
        _evictChunksIfNeeded();
        completer.complete(_memoryCache.containsChunk(chunkIndex));
      } catch (e, st) {
        if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
          logger('chunk task failed: chunk=$chunkIndex, e=$e\n$st');
        }
        completer.completeError(e, st);
      } finally {
        _activeWorkers = max(0, _activeWorkers - 1);
        _inFlight.remove(chunkIndex);
        _abortedChunks.remove(chunkIndex); // cleanup
        _ignoreWindowChunks.remove(chunkIndex);
        _semaphore.release();
      }
    }());
  }

  /// Waits for a chunk to be ready in the cache. Starts the download if not
  /// already in-flight. Returns true if the chunk is available for reading.
  Future<bool> _waitForChunk(int chunkIndex) async {
    if (_mode == ProxyMode.single) return false;
    if (_memoryCache.containsChunk(chunkIndex)) return true;

    final existing = _inFlight[chunkIndex];
    if (existing != null) {
      try {
        return await existing.future;
      } catch (_) {
        return false;
      }
    }

    // Not yet started — kick it off now and wait.
    _startPrefetch(chunkIndex);
    final started = _inFlight[chunkIndex];
    if (started == null) {
      // _startPrefetch found it already done (race), check the set.
      return _memoryCache.containsChunk(chunkIndex);
    }
    try {
      return await started.future;
    } catch (_) {
      return false;
    }
  }

  _RequestRange? _normalizeRequestedRange(
    _RequestRange? range,
    int length, {
    int? maxOpenEndedBytes,
  }) {
    if (length <= 0) return null;
    if (range == null) {
      return _RequestRange(start: 0, end: length - 1);
    }

    var start = range.start;
    var end = range.end ?? (length - 1);
    if (range.end == null &&
        maxOpenEndedBytes != null &&
        maxOpenEndedBytes > 0) {
      end = min(end, start + maxOpenEndedBytes - 1);
    }
    if (start < 0) start = 0;
    if (start >= length) return null;
    if (end >= length) end = length - 1;
    if (end < start) return null;
    return _RequestRange(start: start, end: end);
  }

  String? _rangeHeaderValue(_RequestRange? range) {
    if (range == null) return null;
    if (range.end == null) {
      return 'bytes=${range.start}-';
    }
    return 'bytes=${range.start}-${range.end}';
  }

  _RequestRange? _parseRangeHeader(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1) ?? '');
    final endRaw = match.group(2) ?? '';
    final end = endRaw.isEmpty ? null : int.tryParse(endRaw);
    if (start == null || start < 0) return null;
    return _RequestRange(start: start, end: end);
  }

  int _bufferedBytesAhead() {
    if (_mode == ProxyMode.single) return 0;
    final length = _contentLength;
    if (length == null || length <= 0) return 0;
    return _memoryCache.bufferedBytesAhead(_playbackOffset, length);
  }

  Future<_RangeProbeResult> _probeRangeSupport() async {
    try {
      final uri = Uri.parse(sourceUrl);
      final req = await _client.getUrl(uri);
      _applyHeaders(req.headers, headers);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      _logUpstreamRequestHeaders('probeRangeSupport', req.headers);
      final resp = await req.close();
      final status = resp.statusCode;
      final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
      final total =
          _parseTotalLengthFromContentRange(contentRange) ??
          int.tryParse(
            resp.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          );
      final contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      await resp.drain<void>();
      if (status == HttpStatus.partialContent) {
        return _RangeProbeResult(
          supportsRange: true,
          contentLength: total,
          contentType: contentType,
        );
      }
      if (status == HttpStatus.ok) {
        return _RangeProbeResult(
          supportsRange: false,
          contentLength: total,
          contentType: contentType,
        );
      }
      return const _RangeProbeResult(
        supportsRange: false,
        contentLength: null,
        contentType: null,
      );
    } catch (_) {
      return const _RangeProbeResult(
        supportsRange: false,
        contentLength: null,
        contentType: null,
      );
    }
  }

  int? _parseTotalLengthFromContentRange(String? contentRange) {
    if (contentRange == null || contentRange.isEmpty) return null;
    final match = RegExp(r'^bytes\s+\d+-\d+\/(\d+)$').firstMatch(contentRange);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  void _copyResponseHeaders(HttpHeaders from, HttpHeaders to) {
    const blocked = <String>{
      'transfer-encoding',
      'connection',
      'keep-alive',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailer',
      'upgrade',
    };
    from.forEach((name, values) {
      if (blocked.contains(name.toLowerCase())) return;
      for (final value in values) {
        to.add(name, value);
      }
    });
  }

  void _applyHeaders(HttpHeaders target, Map<String, String> source) {
    for (final entry in source.entries) {
      target.set(entry.key, entry.value);
    }
  }

  void _logUpstreamRequestHeaders(String scene, HttpHeaders requestHeaders) {
    if (!_verboseUpstreamHeaderLogs) return;
    final referer = requestHeaders.value(HttpHeaders.refererHeader) ?? '';
    final userAgent = requestHeaders.value(HttpHeaders.userAgentHeader) ?? '';
    final cookie = requestHeaders.value(HttpHeaders.cookieHeader) ?? '';
    final range = requestHeaders.value(HttpHeaders.rangeHeader) ?? '';
    logger(
      'session=$sessionId upstream[$scene] headers: '
      'referer="$referer", ua="$userAgent", cookie="$cookie", range="$range"',
    );
  }

  void _recordDownloadedBytes(int bytes) {
    if (bytes <= 0) return;
    _downloadBytesTotal += bytes;
    onDownloadBytes(bytes);
  }

  void _recordServedBytes(int bytes) {
    if (bytes <= 0) return;
    _serveBytesTotal += bytes;
  }

  void _degradeToSingle(String reason) {
    if (_mode == ProxyMode.single) return;
    _mode = ProxyMode.single;
    _degradeReason = reason;
    logger('session=$sessionId degraded to single mode: $reason');
  }

  Future<bool> _ensureChunkReady(int chunkIndex) => _waitForChunk(chunkIndex);

  bool _isClientClosedError(Object error) {
    if (error is! StateError) return false;
    return error.message.toString().contains('Client is closed');
  }
}

class _RangeMemoryCache {
  _RangeMemoryCache({required this.chunkSize, required this.maxBytes});

  final int chunkSize;
  final int maxBytes;
  final Map<int, Uint8List> _chunks = <int, Uint8List>{};
  final LinkedHashMap<int, void> _lru = LinkedHashMap<int, void>();
  final SplayTreeMap<int, _RangeSpan> _ranges = SplayTreeMap<int, _RangeSpan>();
  int currentBytes = 0;

  void clear() {
    _chunks.clear();
    _lru.clear();
    _ranges.clear();
    currentBytes = 0;
  }

  int get chunkCount => _chunks.length;
  Iterable<int> get chunkIndices => _chunks.keys;
  int? get oldestChunkIndex => _lru.isEmpty ? null : _lru.keys.first;
  List<_RangeSpan> get cachedRanges => _ranges.values.toList(growable: false);

  bool containsChunk(int chunkIndex) => _chunks.containsKey(chunkIndex);

  Uint8List? peekChunk(int chunkIndex) => _chunks[chunkIndex];

  void touchChunk(int chunkIndex) {
    if (!_chunks.containsKey(chunkIndex)) return;
    _lru.remove(chunkIndex);
    _lru[chunkIndex] = null;
  }

  void putChunk(int chunkIndex, Uint8List data) {
    final existing = _chunks[chunkIndex];
    if (existing != null) {
      currentBytes -= existing.length;
    }
    _chunks[chunkIndex] = data;
    currentBytes += data.length;
    touchChunk(chunkIndex);
    _rebuildRanges();
  }

  bool removeChunk(int chunkIndex) {
    final removed = _chunks.remove(chunkIndex);
    _lru.remove(chunkIndex);
    if (removed == null) return false;
    currentBytes = max(0, currentBytes - removed.length);
    _rebuildRanges();
    return true;
  }

  int countCachedBytesInRange(int start, int end, int contentLength) {
    if (_ranges.isEmpty || contentLength <= 0) return 0;
    final upper = max(0, contentLength - 1);
    final boundedStart = min(max(start, 0), upper);
    final boundedEnd = min(max(end, 0), upper);
    if (boundedEnd < boundedStart) return 0;

    var total = 0;
    for (final span in _ranges.values) {
      if (span.end < boundedStart) continue;
      if (span.start > boundedEnd) break;
      final overlapStart = max(boundedStart, span.start);
      final overlapEnd = min(boundedEnd, span.end);
      if (overlapEnd >= overlapStart) {
        total += overlapEnd - overlapStart + 1;
      }
    }
    return total;
  }

  int bufferedBytesAhead(int playbackOffset, int contentLength) {
    if (contentLength <= 0) return 0;
    final boundedOffset = min(
      max(playbackOffset, 0),
      max(0, contentLength - 1),
    );
    final startChunk = boundedOffset ~/ chunkSize;
    var total = 0;
    var idx = startChunk;
    while (true) {
      final data = _chunks[idx];
      if (data == null || data.isEmpty) break;
      final chunkStart = idx * chunkSize;
      final chunkEnd = min(contentLength - 1, chunkStart + data.length - 1);
      if (idx == startChunk) {
        total += max(0, chunkEnd - boundedOffset + 1);
      } else {
        total += max(0, chunkEnd - chunkStart + 1);
      }
      idx += 1;
    }
    return total;
  }

  void _rebuildRanges() {
    _ranges.clear();
    if (_chunks.isEmpty) return;

    final sorted = _chunks.keys.toList()..sort();
    var runStart = sorted.first;
    var runEnd = sorted.first;
    for (final idx in sorted.skip(1)) {
      if (idx == runEnd + 1) {
        runEnd = idx;
        continue;
      }
      _addRange(runStart, runEnd);
      runStart = idx;
      runEnd = idx;
    }
    _addRange(runStart, runEnd);
  }

  void _addRange(int startChunkIndex, int endChunkIndex) {
    final startByte = startChunkIndex * chunkSize;
    final lastChunk = _chunks[endChunkIndex];
    if (lastChunk == null || lastChunk.isEmpty) return;
    final endByte = endChunkIndex * chunkSize + lastChunk.length - 1;
    _ranges[startByte] = _RangeSpan(start: startByte, end: endByte);
  }
}

class _RangeSpan {
  const _RangeSpan({required this.start, required this.end});

  final int start;
  final int end;
}

class _RangeProbeResult {
  const _RangeProbeResult({
    required this.supportsRange,
    required this.contentLength,
    required this.contentType,
  });

  final bool supportsRange;
  final int? contentLength;
  final String? contentType;
}

class _RequestRange {
  const _RequestRange({required this.start, this.end});

  final int start;
  final int? end;
}

class _AsyncSemaphore {
  _AsyncSemaphore(this._capacity);

  final int _capacity;
  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_inUse < _capacity) {
      _inUse += 1;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.addLast(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.complete();
      return;
    }
    _inUse = max(0, _inUse - 1);
  }
}

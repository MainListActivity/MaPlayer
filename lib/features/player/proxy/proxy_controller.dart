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
  static const int _aheadWindowBytes = 192 * 1024 * 1024;
  static const int _behindWindowBytes = 32 * 1024 * 1024;
  static const int _maxOpenEndedResponseBytes = 64 * 1024 * 1024;
  static const int _maxCacheBytes = 2 * 1024 * 1024 * 1024;

  final Map<String, _ProxySession> _sessions = <String, _ProxySession>{};
  StreamController<ProxyAggregateStats>? _aggregateStatsController;
  LocalStreamProxyServer? _server;
  Timer? _aggregateStatsTimer;
  int _aggregateDownloadedBytesTotal = 0;
  int _aggregateDownloadedBytesLast = 0;
  DateTime _aggregateStatsLastAt = DateTime.now();

  bool get _isSupportedPlatform => Platform.isMacOS || Platform.isWindows;

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

    final cacheRoot = await _resolveCacheRoot();
    await _evictOldCaches(cacheRoot, _maxCacheBytes);

    final createdAt = DateTime.now();
    final session = _ProxySession(
      sessionId: sessionId,
      sourceUrl: media.url,
      headers: media.headers,
      createdAt: createdAt,
      cacheRoot: cacheRoot,
      streamUrl: _server!.urlForSession(sessionId),
      logger: _log,
      onDownloadBytes: _recordAggregateDownloadedBytes,
      chunkSize: _chunkSize,
      maxConcurrency: _maxConcurrency,
      aheadWindowBytes: _aheadWindowBytes,
      behindWindowBytes: _behindWindowBytes,
      maxOpenEndedResponseBytes: _maxOpenEndedResponseBytes,
      maxCacheBytes: _maxCacheBytes,
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

  Stream<ProxyStatsSnapshot> watchStats(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      return const Stream<ProxyStatsSnapshot>.empty();
    }
    return session.statsStream;
  }

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

  Future<Directory> _resolveCacheRoot() async {
    String path;
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      path = '$home/Library/Caches/ma_player/proxy_cache';
    } else if (Platform.isWindows) {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
      path = '$localAppData\\ma_player\\proxy_cache';
    } else {
      path = '${Directory.systemTemp.path}/ma_player_proxy_cache';
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _evictOldCaches(Directory root, int maxBytes) async {
    final files = <File>[];
    await for (final entity in root.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is File && entity.path.endsWith('.bin')) {
        files.add(entity);
      }
    }
    if (files.isEmpty) return;

    var total = 0;
    final metas = <(File file, DateTime modified, int size)>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        total += stat.size;
        metas.add((file, stat.modified, stat.size));
      } catch (_) {
        // Ignore broken entries.
      }
    }
    if (total <= maxBytes) return;

    metas.sort((a, b) => a.$2.compareTo(b.$2));
    for (final item in metas) {
      if (total <= maxBytes) break;
      try {
        await item.$1.delete();
        final jsonPath = item.$1.path.replaceAll(RegExp(r'\.bin$'), '.json');
        final sidecar = File(jsonPath);
        if (await sidecar.exists()) {
          await sidecar.delete();
        }
        total -= item.$3;
      } catch (_) {
        // Ignore delete failure and continue.
      }
    }
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
  LocalStreamProxyServer({
    required this.onStreamRequest,
    required this.logger,
  });

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
      logger(
        'incoming request: method=${request.method} path=$path '
        'range=${request.headers.value(HttpHeaders.rangeHeader) ?? ''}',
      );
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
    required this.cacheRoot,
    required this.streamUrl,
    required this.logger,
    required this.onDownloadBytes,
    required this.chunkSize,
    required this.maxConcurrency,
    required this.aheadWindowBytes,
    required this.behindWindowBytes,
    required this.maxOpenEndedResponseBytes,
    required this.maxCacheBytes,
  }) : _client = HttpClient(),
       _semaphore = _AsyncSemaphore(maxConcurrency);

  final String sessionId;
  final String sourceUrl;
  final Map<String, String> headers;
  final DateTime createdAt;
  final Directory cacheRoot;
  final String streamUrl;
  final void Function(String message) logger;
  final void Function(int bytes) onDownloadBytes;
  final int chunkSize;
  final int maxConcurrency;
  final int aheadWindowBytes;
  final int behindWindowBytes;
  final int maxOpenEndedResponseBytes;
  final int maxCacheBytes;
  static const bool _verboseUpstreamHeaderLogs = false;

  final HttpClient _client;
  final _AsyncSemaphore _semaphore;
  final _AsyncSemaphore _writeLock = _AsyncSemaphore(1);
  final StreamController<ProxyStatsSnapshot> _statsController =
      StreamController<ProxyStatsSnapshot>.broadcast();
  final Map<int, Completer<bool>> _inFlight = <int, Completer<bool>>{};
  final Set<int> _downloadedChunks = <int>{};
  // Chunks downloaded from network but not yet flushed to disk. Serve reads
  // from here first so it doesn't have to wait for the write lock.
  final Map<int, List<List<int>>> _chunkBuffer = <int, List<List<int>>>{};
  // LRU tracking: insertion order = access order; head = oldest entry.
  final LinkedHashSet<int> _chunkAccessOrder = LinkedHashSet();
  // Tracks in-progress disk write futures so dispose can await them.
  final Set<Future<void>> _pendingPersists = <Future<void>>{};

  late final File _cacheFile;
  late final File _metaFile;
  late final int _maxChunks;
  RandomAccessFile? _writeRaf;

  Timer? _statsTimer;
  Timer? _metaDebounceTimer;
  DateTime _lastAccessAt = DateTime.now();
  bool _isDisposing = false;
  bool _isDisposed = false;

  ProxyMode _mode = ProxyMode.parallel;
  String? _degradeReason;
  int? _contentLength;

  int _activeWorkers = 0;
  int _playbackOffset = 0;
  static const int _seekThresholdBytes = 4 * 1024 * 1024; // 4 MB
  final Set<int> _abortedChunks = <int>{};

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
  );

  Future<void> initialize() async {
    _maxChunks = (maxCacheBytes ~/ chunkSize).clamp(16, 1024);
    _cacheFile = File('${cacheRoot.path}/$sessionId.bin');
    _metaFile = File('${cacheRoot.path}/$sessionId.json');

    // --- Read cached meta (best effort) ---
    int? cachedContentLength;
    List<int> cachedChunks = const [];
    if (await _metaFile.exists()) {
      try {
        final raw = await _metaFile.readAsString();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        cachedContentLength = map['contentLength'] as int?;
        final chunksRaw = map['downloadedChunks'];
        if (chunksRaw is List) {
          cachedChunks = chunksRaw.map((e) => (e as num).toInt()).toList();
        }
      } catch (_) {
        // Corrupt meta — treat as cold start.
        cachedContentLength = null;
        cachedChunks = const [];
      }
    }

    // --- Probe remote ---
    final probe = await _probeRangeSupport();
    _contentLength = probe.contentLength;
    _contentType = probe.contentType;

    // --- Warm-cache: validate and restore ---
    final canWarm = cachedContentLength != null &&
        _contentLength != null &&
        cachedContentLength == _contentLength &&
        cachedChunks.isNotEmpty &&
        await _cacheFile.exists();

    if (canWarm) {
      // Open in append mode — does NOT truncate existing data.
      _writeRaf = await _cacheFile.open(mode: FileMode.writeOnlyAppend);
      _downloadedChunks.addAll(cachedChunks);
      for (final idx in cachedChunks) {
        _chunkAccessOrder.add(idx);
      }
      logger(
        'session=$sessionId warm-cache restored '
        '${cachedChunks.length} chunks (contentLength=$_contentLength)',
      );
    } else {
      // Only discard the cache when a definitive content-length mismatch is
      // detected (both sides are known and differ). A probe failure
      // (_contentLength == null) is likely a transient network issue — leave
      // the cache files in place so they can be reused on the next open.
      final definiteMismatch = cachedContentLength != null &&
          _contentLength != null &&
          cachedContentLength != _contentLength;
      if (definiteMismatch) {
        if (await _cacheFile.exists()) {
          try { await _cacheFile.delete(); } catch (_) {}
        }
        if (await _metaFile.exists()) {
          try { await _metaFile.delete(); } catch (_) {}
        }
        logger(
          'session=$sessionId cache invalidated: '
          'cachedLength=$cachedContentLength remoteLength=$_contentLength',
        );
      }
      if (!await _cacheFile.exists()) {
        await _cacheFile.create(recursive: true);
      }
      _writeRaf = await _cacheFile.open(mode: FileMode.write);
    }

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
      final elapsedMs = max(1, now.difference(_statsLastSampleAt).inMilliseconds);
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
    _lastAccessAt = DateTime.now();
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
    _metaDebounceTimer?.cancel();
    final inflight = _inFlight.values.toList(growable: false);
    if (inflight.isNotEmpty) {
      await Future.wait(
        inflight.map((c) => c.future.then((_) {}, onError: (_) {})),
      );
    }
    _client.close(force: true);
    // Wait for any in-progress disk writes before closing the file handle.
    if (_pendingPersists.isNotEmpty) {
      await Future.wait(
        _pendingPersists.toList().map((f) => f.catchError((_) {})),
      );
    }
    await _writeRaf?.flush();
    await _writeRaf?.close();
    _writeRaf = null;
    await _writeMeta();
    await _statsController.close();
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

    await for (final chunk in upstreamResponse) {
      _recordDownloadedBytes(chunk.length);
      _recordServedBytes(chunk.length);
      request.response.add(chunk);
    }
    await request.response.close();
  }

  /// Streams the requested range directly from the upstream source to the
  /// client, bypassing the chunk cache. Used immediately after a seek so
  /// media_kit gets data without waiting for background downloads to complete.
  /// Does not write to the cache to avoid races with parallel prefetch tasks.
  Future<void> _serveBridge(HttpRequest request, _RequestRange requested) async {
    if (_isDisposing || _isDisposed) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    final length = _contentLength!;
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentType ?? 'video/mp4',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${requested.end! - requested.start + 1}',
    );
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes ${requested.start}-${requested.end!}/$length',
    );

    try {
      final uri = Uri.parse(sourceUrl);
      final upstreamRequest = await _client.getUrl(uri);
      _applyHeaders(upstreamRequest.headers, headers);
      upstreamRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=${requested.start}-${requested.end!}',
      );
      _logUpstreamRequestHeaders('serveBridge', upstreamRequest.headers);

      final upstreamResponse = await upstreamRequest.close();
      await for (final chunk in upstreamResponse) {
        _recordDownloadedBytes(chunk.length);
        _recordServedBytes(chunk.length);
        request.response.add(chunk);
      }
    } catch (e) {
      if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
        logger('session=$sessionId bridge failed: $e');
      }
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

    final requested = _normalizeRequestedRange(
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

    final requested = _normalizeRequestedRange(
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

    // Detect seek: large jump from current playback position.
    final isSeek =
        requested.start > 0 &&
        _playbackOffset > 0 &&
        (requested.start - _playbackOffset).abs() > _seekThresholdBytes;
    if (isSeek) {
      logger(
        'session=$sessionId seek detected: '
        'from=$_playbackOffset to=${requested.start}, '
        'aborting out-of-window prefetch tasks',
      );
      _abortOutOfWindowChunks(requested.start);
    }
    _playbackOffset = requested.start;

    if (isSeek) {
      // Bridge: stream directly from upstream so media_kit gets data
      // immediately without waiting for background chunks to arrive.
      // Kick off background prefetch while the bridge serves the response.
      _ensureRangeAvailableBackground(requested.start);
      await _serveBridge(request, requested);
      return;
    }

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

    final raf = await _cacheFile.open(mode: FileMode.read);
    var degraded = false;
    try {
      var offset = requested.start;
      final end = requested.end!;
      while (offset <= end) {
        final chunkIndex = offset ~/ chunkSize;
        _touchChunk(chunkIndex);
        final chunkReady = await _ensureChunkReady(chunkIndex);
        if (!chunkReady || _mode == ProxyMode.single) {
          _degradeToSingle('chunk $chunkIndex not ready during serve');
          degraded = true;
          break;
        }
        final remaining = end - offset + 1;
        final readLen = min(remaining, 64 * 1024);

        // Try in-memory buffer first (chunk downloaded but disk write pending).
        final bufData = _chunkBuffer[chunkIndex];
        List<int> data;
        if (bufData != null) {
          // Assemble the bytes needed from the in-memory buffer.
          final chunkStart = chunkIndex * chunkSize;
          final localOffset = offset - chunkStart;
          var collected = 0;
          final builder = BytesBuilder(copy: false);
          var pos = 0;
          for (final segment in bufData) {
            final segEnd = pos + segment.length;
            if (segEnd <= localOffset) {
              pos = segEnd;
              continue;
            }
            final from = max(0, localOffset - pos);
            final take = min(segment.length - from, readLen - collected);
            builder.add(
              from == 0 && take == segment.length
                  ? segment
                  : segment.sublist(from, from + take),
            );
            collected += take;
            pos = segEnd;
            if (collected >= readLen) break;
          }
          data = builder.takeBytes();
        } else {
          // Chunk already persisted to disk — read from cache file.
          await raf.setPosition(offset);
          data = await raf.read(readLen);
        }

        if (data.isEmpty) {
          throw StateError('cache data missing at offset=$offset after chunk ready');
        }
        _recordServedBytes(data.length);
        request.response.add(data);
        offset += data.length;
        _playbackOffset = offset;
      }
    } finally {
      await raf.close();
    }
    if (degraded) {
      await _serveSingle(request, requested);
      return;
    }
    await request.response.close();
  }

  Future<void> _ensureRangeAvailable(int start, int end) async {
    final length = _contentLength;
    if (length == null || length <= 0) return;

    final needStartChunk = start ~/ chunkSize;
    final needEndChunk = end ~/ chunkSize;

    final windowStart = max(0, start - behindWindowBytes);
    final windowEnd = min(length - 1, start + aheadWindowBytes);
    final prefetchStartChunk = windowStart ~/ chunkSize;
    final prefetchEndChunk = windowEnd ~/ chunkSize;

    // Start all prefetch chunks in the background (non-blocking).
    for (var i = prefetchStartChunk; i <= prefetchEndChunk; i++) {
      _startPrefetch(i);
    }

    // Track cache hit stats.
    final requestedBytes = end - start + 1;
    _requestedBytes += requestedBytes;
    final cachedChunks = _countCachedChunksInRange(needStartChunk, needEndChunk);
    _cacheHitBytes += cachedChunks * chunkSize;

    // Wait for the chunks that are required for the current request.
    for (var i = needStartChunk; i <= needEndChunk; i++) {
      final ok = await _waitForChunk(i);
      if (!ok || _mode == ProxyMode.single) return;
    }
  }

  /// Kicks off background prefetch for the window around [start] without
  /// waiting for any chunk to complete. Used on seek to warm the cache while
  /// _serveBridge handles the immediate response.
  void _ensureRangeAvailableBackground(int start) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    final windowStart = max(0, start - behindWindowBytes);
    final windowEnd = min(length - 1, start + aheadWindowBytes);
    final prefetchStartChunk = windowStart ~/ chunkSize;
    final prefetchEndChunk = windowEnd ~/ chunkSize;
    for (var i = prefetchStartChunk; i <= prefetchEndChunk; i++) {
      _startPrefetch(i);
    }
  }

  int _countCachedChunksInRange(int startChunk, int endChunk) {
    var count = 0;
    for (var i = startChunk; i <= endChunk; i++) {
      if (_downloadedChunks.contains(i)) {
        count += 1;
      }
    }
    return count;
  }

  void _touchChunk(int chunkIndex) {
    _chunkAccessOrder.remove(chunkIndex);
    _chunkAccessOrder.add(chunkIndex);
  }

  void _evictChunksIfNeeded() {
    while (_downloadedChunks.length > _maxChunks) {
      if (_chunkAccessOrder.isEmpty) break;
      final oldest = _chunkAccessOrder.first;
      _downloadedChunks.remove(oldest);
      _chunkBuffer.remove(oldest);
      _chunkAccessOrder.remove(oldest);
    }
  }

  /// Downloads a chunk from the network and returns the received data.
  /// Returns null on failure (after retries). Does NOT write to disk.
  Future<List<List<int>>?> _downloadChunk(int chunkIndex) async {
    final length = _contentLength;
    if (length == null || length <= 0) return null;

    final start = chunkIndex * chunkSize;
    if (start >= length) return const <List<int>>[];
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
          final chunks = <List<int>>[];
          await for (final data in resp) {
            _recordDownloadedBytes(data.length);
            received += data.length;
            chunks.add(data);
          }
          if (received == expectedBytes) {
            return chunks;
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

  /// Writes chunk data to the shared RAF under the write lock.
  /// Removes the chunk from [_chunkBuffer] when done.
  Future<void> _persistChunk(int chunkIndex, List<List<int>> data) async {
    final length = _contentLength;
    if (length == null) return;
    final start = chunkIndex * chunkSize;
    // Skip write if this chunk was aborted during a seek.
    if (_abortedChunks.contains(chunkIndex)) {
      _chunkBuffer.remove(chunkIndex);
      return;
    }
    await _writeLock.acquire();
    try {
      final raf = _writeRaf;
      if (raf == null) return; // Session disposed; cache file already closed.
      await raf.setPosition(start);
      for (final chunk in data) {
        await raf.writeFrom(chunk);
      }
    } finally {
      _writeLock.release();
      _chunkBuffer.remove(chunkIndex);
      _scheduleMeta();
    }
  }

  Future<void> _writeMeta() async {
    try {
      final payload = <String, dynamic>{
        'sessionId': sessionId,
        'sourceUrl': sourceUrl,
        'mode': _mode.name,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessAt': _lastAccessAt.toIso8601String(),
        'contentLength': _contentLength,
        'downloadedChunks': (_downloadedChunks.toList()..sort()),
        'downloadedChunkCount': _downloadedChunks.length,
        'degradeReason': _degradeReason,
      };
      await _metaFile.writeAsString(jsonEncode(payload));
    } catch (_) {
      // Best effort only.
    }
  }

  void _scheduleMeta() {
    if (_isDisposing || _isDisposed) return;
    _metaDebounceTimer?.cancel();
    _metaDebounceTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_writeMeta());
    });
  }

  /// Marks all in-flight chunks outside the new prefetch window as aborted.
  /// Aborted tasks check [_abortedChunks] at key points and exit early,
  /// releasing their semaphore slot immediately.
  void _abortOutOfWindowChunks(int newStart) {
    final length = _contentLength;
    if (length == null || length <= 0) return;
    final windowStartChunk = max(0, newStart - behindWindowBytes) ~/ chunkSize;
    final windowEndChunk =
        min(length - 1, newStart + aheadWindowBytes) ~/ chunkSize;
    // Clear stale abort markers so previously-aborted chunks that fall back
    // inside the new window are not permanently blacklisted.
    _abortedChunks.clear();
    for (final idx in _inFlight.keys.toList()) {
      if (idx < windowStartChunk || idx > windowEndChunk) {
        _abortedChunks.add(idx);
      }
    }
  }

  /// Starts a chunk download in the background. Does not wait for completion.
  /// Idempotent: no-op if the chunk is already downloaded or already in-flight.
  void _startPrefetch(int chunkIndex) {
    if (_mode == ProxyMode.single) return;
    final length = _contentLength;
    if (length == null || length <= 0) return;
    if (chunkIndex < 0 || chunkIndex * chunkSize >= length) return;
    if (_downloadedChunks.contains(chunkIndex)) return;
    if (_inFlight.containsKey(chunkIndex)) return;

    final completer = Completer<bool>();
    _inFlight[chunkIndex] = completer;

    unawaited(() async {
      await _semaphore.acquire();
      _activeWorkers += 1;
      try {
        // Checkpoint 1: abort before doing any work (seek cleared this slot).
        if (_abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (_downloadedChunks.contains(chunkIndex)) {
          completer.complete(true);
          return;
        }
        if (_mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        final data = await _downloadChunk(chunkIndex);
        // Checkpoint 2: abort after download completes (seek happened mid-download).
        if (_abortedChunks.contains(chunkIndex)) {
          completer.complete(false);
          return;
        }
        if (data == null || _mode != ProxyMode.parallel) {
          completer.complete(false);
          return;
        }
        // Store in memory buffer so serve can read immediately.
        _chunkBuffer[chunkIndex] = data;
        _downloadedChunks.add(chunkIndex);
        _touchChunk(chunkIndex);
        _evictChunksIfNeeded();
        // Signal serve that the chunk is ready before disk write completes.
        completer.complete(true);
        // Persist to disk asynchronously — does not block serve.
        final persistFuture = _persistChunk(chunkIndex, data);
        _pendingPersists.add(persistFuture);
        unawaited(persistFuture.whenComplete(() => _pendingPersists.remove(persistFuture)));
      } catch (e, st) {
        if (!_isDisposing && !_isDisposed && !_isClientClosedError(e)) {
          logger('chunk task failed: chunk=$chunkIndex, e=$e\n$st');
        }
        completer.completeError(e, st);
      } finally {
        _activeWorkers = max(0, _activeWorkers - 1);
        _inFlight.remove(chunkIndex);
        _abortedChunks.remove(chunkIndex); // cleanup
        _semaphore.release();
      }
    }());
  }

  /// Waits for a chunk to be ready in the cache. Starts the download if not
  /// already in-flight. Returns true if the chunk is available for reading.
  Future<bool> _waitForChunk(int chunkIndex) async {
    if (_mode == ProxyMode.single) return false;
    if (_downloadedChunks.contains(chunkIndex)) return true;

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
      return _downloadedChunks.contains(chunkIndex);
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

    final startChunk = _playbackOffset ~/ chunkSize;
    var total = 0;
    var idx = startChunk;
    while (true) {
      if (!_downloadedChunks.contains(idx)) break;
      final chunkStart = idx * chunkSize;
      final chunkEnd = min(length - 1, chunkStart + chunkSize - 1);
      if (idx == startChunk) {
        total += max(0, chunkEnd - _playbackOffset + 1);
      } else {
        total += (chunkEnd - chunkStart + 1);
      }
      idx += 1;
    }
    return total;
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

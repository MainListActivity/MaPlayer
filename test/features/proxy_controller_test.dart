import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/playback/playback_models.dart';
import 'package:ma_palyer/features/player/proxy/proxy_controller.dart';

class _FakeVideoUpstream {
  _FakeVideoUpstream({
    required this.contentLength,
    this.supportsRange = true,
    this.chunkWriteDelay = Duration.zero,
  });

  final int contentLength;
  final bool supportsRange;
  final Duration chunkWriteDelay;
  final List<String> rangeRequests = <String>[];
  HttpServer? _server;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  String get url {
    final server = _server;
    if (server == null) {
      throw StateError('upstream not started');
    }
    return 'http://${server.address.address}:${server.port}/video.raw';
  }

  Future<void> _handle(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (!supportsRange) {
      if (range != null && range.isNotEmpty) {
        rangeRequests.add(range);
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        '$contentLength',
      );
      await _writePattern(request.response, 0, contentLength - 1);
      await request.response.close();
      return;
    }
    if (range == null || range.isEmpty) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        '$contentLength',
      );
      await _writePattern(request.response, 0, contentLength - 1);
      await request.response.close();
      return;
    }
    rangeRequests.add(range);
    final parsed = _parseRange(range);
    if (parsed == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$contentLength',
      );
      await request.response.close();
      return;
    }
    final start = parsed.$1;
    final end = parsed.$2;
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$contentLength',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '${end - start + 1}',
    );
    await _writePattern(request.response, start, end);
    await request.response.close();
  }

  (int, int)? _parseRange(String value) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1) ?? '');
    if (start == null || start < 0 || start >= contentLength) return null;
    final endRaw = match.group(2) ?? '';
    final end = endRaw.isEmpty
        ? contentLength - 1
        : min(contentLength - 1, int.tryParse(endRaw) ?? contentLength - 1);
    if (end < start) return null;
    return (start, end);
  }

  Future<void> _writePattern(HttpResponse response, int start, int end) async {
    var offset = start;
    while (offset <= end) {
      final size = min(64 * 1024, end - offset + 1);
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = (offset + i) & 0xFF;
      }
      response.add(bytes);
      if (chunkWriteDelay > Duration.zero) {
        await Future<void>.delayed(chunkWriteDelay);
      }
      offset += size;
    }
  }
}

void main() {
  final supported = Platform.isMacOS || Platform.isWindows;

  group('ProxyController', () {
    setUp(() {
      ProxyController.debugSessionCacheWindowBytesOverride = 8 * 1024 * 1024;
      ProxyController.debugPriorityBufferSecondsOverride = 120;
    });

    tearDown(() async {
      await ProxyController.instance.dispose();
      ProxyController.debugSessionCacheWindowBytesOverride = null;
      ProxyController.debugPriorityBufferSecondsOverride = null;
    });

    test(
      'serves second same range from local cache without extra upstream fetch',
      () async {
        final upstream = _FakeVideoUpstream(contentLength: 6 * 1024 * 1024);
        await upstream.start();
        try {
          final endpoint = await ProxyController.instance.createSession(
            PlayableMedia(
              url: upstream.url,
              headers: const <String, String>{},
              subtitle: null,
              progressKey: 'p1',
            ),
            fileKey: 'proxy-test-cache-hit',
          );
          final proxyUrl = endpoint.playbackUrl;
          final firstLen = await _fetchRangeBytes(proxyUrl, 0, 256 * 1024 - 1);
          expect(firstLen, 256 * 1024);
          await _waitForRequestQuiet(upstream);
          final before = upstream.rangeRequests.length;

          final secondLen = await _fetchRangeBytes(proxyUrl, 0, 256 * 1024 - 1);
          expect(secondLen, 256 * 1024);
          await _waitForRequestQuiet(upstream);
          final after = upstream.rangeRequests.length;
          expect(after, before);
        } finally {
          await upstream.stop();
        }
      },
      skip: !supported,
    );

    test(
      'seed/open range updates sliding cache window anchor in meta',
      () async {
        final upstream = _FakeVideoUpstream(contentLength: 80 * 1024 * 1024);
        await upstream.start();
        try {
          final endpoint = await ProxyController.instance.createSession(
            PlayableMedia(
              url: upstream.url,
              headers: const <String, String>{},
              subtitle: null,
              progressKey: 'p2',
            ),
            fileKey: 'proxy-test-seed-window',
          );
          final sessionId = endpoint.proxySession!.sessionId;
          final seedStart = 12 * 1024 * 1024 + 12345;
          final readLen = await _fetchRangeBytes(
            endpoint.playbackUrl,
            seedStart,
            seedStart + 128 * 1024 - 1,
          );
          expect(readLen, 128 * 1024);
          await ProxyController.instance.closeSession(sessionId);

          final meta = await _readSessionMeta(sessionId);
          expect(meta, isNotNull);
          final windowStart = meta!['cacheWindowStart'] as int;
          final windowEnd = meta['cacheWindowEnd'] as int;
          expect(windowStart, seedStart);
          expect(windowEnd, seedStart + 8 * 1024 * 1024 - 1);
        } finally {
          await upstream.stop();
        }
      },
      skip: !supported,
    );

    test(
      'seek moves cache window and evicts old chunks outside new window',
      () async {
        final upstream = _FakeVideoUpstream(contentLength: 80 * 1024 * 1024);
        await upstream.start();
        try {
          final endpoint = await ProxyController.instance.createSession(
            PlayableMedia(
              url: upstream.url,
              headers: const <String, String>{},
              subtitle: null,
              progressKey: 'p3',
            ),
            fileKey: 'proxy-test-window-evict',
          );
          final sessionId = endpoint.proxySession!.sessionId;
          await _fetchRangeBytes(endpoint.playbackUrl, 0, 128 * 1024 - 1);
          await _waitForRequestQuiet(upstream);

          final seekStart = 24 * 1024 * 1024;
          await _fetchRangeBytes(
            endpoint.playbackUrl,
            seekStart,
            seekStart + 128 * 1024 - 1,
          );
          await _waitForRequestQuiet(upstream);
          await ProxyController.instance.closeSession(sessionId);

          final meta = await _readSessionMeta(sessionId);
          expect(meta, isNotNull);
          expect(meta!['cacheWindowStart'], seekStart);
          expect(meta['cacheWindowEnd'], seekStart + 8 * 1024 * 1024 - 1);
          final chunks =
              ((meta['downloadedChunks'] as List?) ?? const <dynamic>[])
                  .cast<num>()
                  .map((e) => e.toInt())
                  .toList();
          final minChunk = seekStart ~/ (2 * 1024 * 1024);
          final maxChunk =
              (seekStart + 8 * 1024 * 1024 - 1) ~/ (2 * 1024 * 1024);
          for (final chunk in chunks) {
            expect(chunk, inInclusiveRange(minChunk, maxChunk));
          }
        } finally {
          await upstream.stop();
        }
      },
      skip: !supported,
    );

    test('seek bridge path advances lastPlaybackPosition', () async {
      final upstream = _FakeVideoUpstream(contentLength: 80 * 1024 * 1024);
      await upstream.start();
      try {
        final endpoint = await ProxyController.instance.createSession(
          PlayableMedia(
            url: upstream.url,
            headers: const <String, String>{},
            subtitle: null,
            progressKey: 'p4',
          ),
          fileKey: 'proxy-test-seek-bridge-offset',
        );
        final sessionId = endpoint.proxySession!.sessionId;

        const warmSize = 128 * 1024;
        const warmStep = 256 * 1024;
        for (var i = 0; i < 4; i++) {
          final start = i * warmStep;
          final bytes = await _fetchRangeBytes(
            endpoint.playbackUrl,
            start,
            start + warmSize - 1,
          );
          expect(bytes, warmSize);
          if (i == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 3200));
          }
        }

        final seekStart = 24 * 1024 * 1024;
        const seekSize = 128 * 1024;
        final seekBytes = await _fetchRangeBytes(
          endpoint.playbackUrl,
          seekStart,
          seekStart + seekSize - 1,
        );
        expect(seekBytes, seekSize);
        await _waitForRequestQuiet(upstream);
        await ProxyController.instance.closeSession(sessionId);

        final meta = await _readSessionMeta(sessionId);
        expect(meta, isNotNull);
        final lastPlaybackPosition = meta!['lastPlaybackPosition'] as int;
        expect(lastPlaybackPosition, greaterThan(seekStart));
      } finally {
        await upstream.stop();
      }
    }, skip: !supported);

    test('single mode updates lastPlaybackPosition while streaming', () async {
      const contentLength = 1024 * 1024;
      final upstream = _FakeVideoUpstream(
        contentLength: contentLength,
        supportsRange: false,
      );
      await upstream.start();
      try {
        final endpoint = await ProxyController.instance.createSession(
          PlayableMedia(
            url: upstream.url,
            headers: const <String, String>{},
            subtitle: null,
            progressKey: 'p5',
          ),
          fileKey: 'proxy-test-single-offset',
        );
        final sessionId = endpoint.proxySession!.sessionId;
        final bytes = await _fetchRangeBytes(
          endpoint.playbackUrl,
          0,
          128 * 1024 - 1,
        );
        expect(bytes, contentLength);
        await ProxyController.instance.closeSession(sessionId);

        final meta = await _readSessionMeta(sessionId);
        expect(meta, isNotNull);
        final lastPlaybackPosition = meta!['lastPlaybackPosition'] as int;
        expect(lastPlaybackPosition, greaterThan(0));
        expect(lastPlaybackPosition, lessThanOrEqualTo(contentLength));
      } finally {
        await upstream.stop();
      }
    }, skip: !supported);

    test('overlapping range request does not trigger seek bridge', () async {
      ProxyController.debugSessionCacheWindowBytesOverride = 64 * 1024 * 1024;
      final upstream = _FakeVideoUpstream(contentLength: 160 * 1024 * 1024);
      await upstream.start();
      try {
        final endpoint = await ProxyController.instance.createSession(
          PlayableMedia(
            url: upstream.url,
            headers: const <String, String>{},
            subtitle: null,
            progressKey: 'p6',
          ),
          fileKey: 'proxy-test-overlap-no-seek',
        );

        const warmSize = 128 * 1024;
        const warmStep = 256 * 1024;
        for (var i = 0; i < 4; i++) {
          final start = i * warmStep;
          final bytes = await _fetchRangeBytes(
            endpoint.playbackUrl,
            start,
            start + warmSize - 1,
          );
          expect(bytes, warmSize);
          if (i == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 3200));
          }
        }

        const firstStart = 0;
        const firstEnd = 12 * 1024 * 1024 - 1;
        final firstBytes = await _fetchRangeBytes(
          endpoint.playbackUrl,
          firstStart,
          firstEnd,
        );
        expect(firstBytes, firstEnd - firstStart + 1);

        const overlapStart = 6 * 1024 * 1024;
        const overlapEnd = 18 * 1024 * 1024 - 1;
        final overlapBytes = await _fetchRangeBytes(
          endpoint.playbackUrl,
          overlapStart,
          overlapEnd,
        );
        expect(overlapBytes, overlapEnd - overlapStart + 1);
        await _waitForRequestQuiet(upstream);

        final bridgeRange = 'bytes=$overlapStart-$overlapEnd';
        final hasBridgeRequest = upstream.rangeRequests.contains(bridgeRange);
        expect(
          hasBridgeRequest,
          isFalse,
          reason:
              'overlap request should be served via chunk cache, not bridge',
        );
      } finally {
        await upstream.stop();
      }
    }, skip: !supported);

    test(
      'startup tail probe does not evict active head cache window',
      () async {
        ProxyController.debugSessionCacheWindowBytesOverride = 64 * 1024 * 1024;
        const contentLength = 160 * 1024 * 1024;
        final upstream = _FakeVideoUpstream(
          contentLength: contentLength,
          chunkWriteDelay: const Duration(milliseconds: 1),
        );
        await upstream.start();
        try {
          final first = await ProxyController.instance.createSession(
            PlayableMedia(
              url: upstream.url,
              headers: const <String, String>{},
              subtitle: null,
              progressKey: 'p7',
            ),
            fileKey: 'proxy-test-startup-probe-window',
          );
          await _fetchRangeBytes(first.playbackUrl, 0, 2 * 1024 * 1024 - 1);
          await ProxyController.instance.closeSession(
            first.proxySession!.sessionId,
          );

          final endpoint = await ProxyController.instance.createSession(
            PlayableMedia(
              url: upstream.url,
              headers: const <String, String>{},
              subtitle: null,
              progressKey: 'p7',
            ),
            fileKey: 'proxy-test-startup-probe-window',
          );
          final sessionId = endpoint.proxySession!.sessionId;

          final headFuture = _fetchOpenEndedBytes(endpoint.playbackUrl, 0);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final tailFuture = _fetchOpenEndedBytes(
            endpoint.playbackUrl,
            contentLength - 8 * 1024 * 1024,
          );
          await Future.wait([headFuture, tailFuture]);

          final headCheck = await _fetchRangeBytes(
            endpoint.playbackUrl,
            0,
            128 * 1024 - 1,
          );
          expect(headCheck, 128 * 1024);
          await ProxyController.instance.closeSession(sessionId);

          final meta = await _readSessionMeta(sessionId);
          expect(meta, isNotNull);
          expect(meta!['mode'], 'parallel');
          expect(meta['degradeReason'], isNull);
        } finally {
          await upstream.stop();
        }
      },
      skip: !supported,
    );
  });
}

Future<int> _fetchRangeBytes(String url, int start, int end) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    final resp = await req.close();
    expect(resp.statusCode, anyOf(HttpStatus.partialContent, HttpStatus.ok));
    var total = 0;
    await for (final chunk in resp) {
      total += chunk.length;
    }
    return total;
  } finally {
    client.close(force: true);
  }
}

Future<int> _fetchOpenEndedBytes(String url, int start) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    final resp = await req.close();
    expect(resp.statusCode, anyOf(HttpStatus.partialContent, HttpStatus.ok));
    var total = 0;
    await for (final chunk in resp) {
      total += chunk.length;
    }
    return total;
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitForRequestQuiet(_FakeVideoUpstream upstream) async {
  var stableTicks = 0;
  var last = upstream.rangeRequests.length;
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final now = upstream.rangeRequests.length;
    if (now == last) {
      stableTicks += 1;
      if (stableTicks >= 3) return;
    } else {
      stableTicks = 0;
      last = now;
    }
  }
}

Future<Map<String, dynamic>?> _readSessionMeta(String sessionId) async {
  final root = await _resolveCacheRoot();
  final file = File('${root.path}/$sessionId.json');
  if (!await file.exists()) return null;
  final raw = await file.readAsString();
  return jsonDecode(raw) as Map<String, dynamic>;
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

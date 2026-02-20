import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ma_palyer/core/spider/spider_engine.dart';

class SpiderProcessManager {
  SpiderProcessManager({
    required this.command,
    this.arguments = const <String>[],
    this.requestTimeout = const Duration(seconds: 20),
    this.logger,
  });

  final String command;
  final List<String> arguments;
  final Duration requestTimeout;
  final SpiderTraceLogger? logger;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
  bool _starting = false;
  bool _inMemoryMode = false;

  Future<void> ensureStarted() async {
    if (_inMemoryMode) return;
    if (_shouldUseInMemoryMode()) {
      _inMemoryMode = true;
      logger?.call(
        'Spider process fallback enabled: macOS App Sandbox detected',
      );
      return;
    }
    if (_process != null) return;
    if (_starting) {
      while (_starting) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return;
    }

    _starting = true;
    try {
      _process = await Process.start(command, arguments);
      _stdoutSub = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onStdoutLine, onDone: _onProcessDone);
      _stderrSub = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            logger?.call('[SpiderProcess stderr] $line');
          }, onDone: () {});
      logger?.call('Spider process started: $command ${arguments.join(' ')}');
    } on ProcessException catch (e) {
      throw SpiderRuntimeException(
        'Failed to start spider process: ${e.message}',
        code: 'PROCESS_START_FAILED',
      );
    } finally {
      _starting = false;
    }
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    await ensureStarted();
    if (_inMemoryMode) {
      return _callInMemory(method, params);
    }
    final process = _process;
    if (process == null) {
      throw SpiderRuntimeException(
        'Spider process not available',
        code: 'PROCESS_UNAVAILABLE',
      );
    }

    final id = _newId(method, params);
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = jsonEncode(<String, dynamic>{
      'id': id,
      'method': method,
      'params': params,
    });

    try {
      process.stdin.writeln(request);
    } on SocketException catch (e) {
      _pending.remove(id);
      throw SpiderRuntimeException(
        'Failed to write request to spider process: ${e.message}',
        code: 'PROCESS_WRITE_FAILED',
        detail: 'method=$method errno=${e.osError?.errorCode}',
      );
    } on StateError catch (e) {
      _pending.remove(id);
      throw SpiderRuntimeException(
        'Spider process stdin is closed: $e',
        code: 'PROCESS_STDIN_CLOSED',
        detail: 'method=$method',
      );
    }

    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw SpiderRuntimeException(
        'Spider call timeout: $method',
        code: 'PROCESS_TIMEOUT',
      );
    }
  }

  void _onStdoutLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final payload = Map<String, dynamic>.from(decoded);
      final id = payload['id']?.toString();
      if (id == null || id.isEmpty) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;

      if (payload['error'] != null) {
        final error = payload['error'];
        if (error is Map) {
          final err = Map<String, dynamic>.from(error);
          completer.completeError(
            SpiderRuntimeException(
              err['message']?.toString() ?? 'Spider runtime error',
              code: err['code']?.toString(),
              detail: err['detail']?.toString(),
            ),
          );
        } else {
          completer.completeError(
            SpiderRuntimeException('Spider runtime error: $error'),
          );
        }
        return;
      }

      final result = payload['result'];
      if (result is Map<String, dynamic>) {
        completer.complete(result);
      } else if (result is Map) {
        completer.complete(Map<String, dynamic>.from(result));
      } else {
        completer.complete(<String, dynamic>{'value': result});
      }
    } catch (e) {
      logger?.call('[SpiderProcess parse error] $e, line=$line');
    }
  }

  void _onProcessDone() {
    final error = SpiderRuntimeException(
      'Spider process exited unexpectedly',
      code: 'PROCESS_EXITED',
    );
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
    _process = null;
  }

  Future<void> dispose() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  String _newId(String method, Map<String, dynamic> params) {
    final input = '${DateTime.now().microsecondsSinceEpoch}:$method:$params';
    return md5.convert(utf8.encode(input)).toString();
  }

  bool _shouldUseInMemoryMode() {
    if (kIsWeb) return true;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }
    if (!Platform.isMacOS) return false;
    return Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');
  }

  Map<String, dynamic> _callInMemory(
    String method,
    Map<String, dynamic> params,
  ) {
    switch (method) {
      case 'init':
        return <String, dynamic>{'ok': true, 'mode': 'in-memory'};
      case 'homeContent':
        return <String, dynamic>{'list': <dynamic>[]};
      case 'categoryContent':
        return <String, dynamic>{
          'list': <dynamic>[],
          'page': 1,
          'pagecount': 1,
        };
      case 'detailContent':
        final idsRaw = params['ids'];
        final ids = (idsRaw is List) ? idsRaw : const <dynamic>[];
        return <String, dynamic>{
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'vod_id': ids.isNotEmpty ? ids.first.toString() : '',
              'vod_name': 'Mock Video',
            },
          ],
        };
      case 'searchContent':
        final key = (params['key'] ?? '').toString();
        return <String, dynamic>{
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'vod_id': 'search:$key',
              'vod_name': key.isEmpty ? 'Mock Search' : key,
            },
          ],
        };
      case 'playerContent':
        final videoId = (params['id'] ?? '').toString();
        if (videoId.startsWith('quark://')) {
          return <String, dynamic>{
            'parse': 0,
            'jx': 0,
            'url': '',
            'playUrl': '',
            'header': jsonEncode(<String, String>{
              'User-Agent': 'MaPlayer-Spider',
            }),
            'quark': <String, dynamic>{
              'shareRef': videoId.replaceFirst('quark://', ''),
              'name': 'Mock Quark File',
            },
          };
        }
        return <String, dynamic>{
          'parse': 0,
          'jx': 0,
          'url': videoId,
          'playUrl': '',
          'header': jsonEncode(<String, String>{
            'User-Agent': 'MaPlayer-Spider',
          }),
        };
      case 'proxyLocal':
        return <String, dynamic>{
          'value': <dynamic>[200, 'application/json', '{}'],
        };
      case 'destroy':
        return <String, dynamic>{'ok': true};
      default:
        throw SpiderRuntimeException(
          'Unsupported method: $method',
          code: 'RUNTIME_ERROR',
        );
    }
  }
}

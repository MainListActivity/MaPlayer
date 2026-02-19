import 'dart:async';

import 'package:ma_palyer/tvbox/tvbox_models.dart';

enum SpiderEngineType { js, jar, py }

class SpiderRuntimeSite {
  const SpiderRuntimeSite({
    required this.sourceKey,
    required this.api,
    required this.ext,
    required this.jar,
  });

  final String sourceKey;
  final String api;
  final String ext;
  final String jar;
}

SpiderEngineType detectEngineFromSite(TvBoxSite site) {
  final api = site.api ?? '';
  if (api.contains('.js')) return SpiderEngineType.js;
  if (api.contains('.py')) return SpiderEngineType.py;
  return SpiderEngineType.jar;
}

abstract class SpiderInstance {
  String get sourceKey;

  Future<Map<String, dynamic>> detailContent(List<String> ids);

  Future<Map<String, dynamic>> playerContent(
    String flag,
    String id,
    List<String> vipFlags,
  );

  Future<Map<String, dynamic>> searchContent(String key, {bool quick = false});

  Future<void> dispose();
}

abstract class SpiderExecutor {
  SpiderEngineType get type;

  Future<void> init(SpiderRuntimeSite site);

  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> params,
  );

  Future<void> destroy();
}

class SpiderRuntimeException implements Exception {
  SpiderRuntimeException(this.message, {this.code, this.detail});

  final String message;
  final String? code;
  final String? detail;

  @override
  String toString() => 'SpiderRuntimeException($code): $message';
}

class SpiderCallTrace {
  SpiderCallTrace({
    required this.traceId,
    required this.method,
    required this.sourceKey,
    required this.startedAt,
  });

  final String traceId;
  final String method;
  final String sourceKey;
  final DateTime startedAt;

  Duration get elapsed => DateTime.now().difference(startedAt);
}

typedef SpiderTraceLogger = void Function(String message);

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

SpiderEngineType detectEngineFromSite(TvBoxSite site, {String? globalSpider}) {
  final api = (site.api ?? '').trim();
  final jar = (site.jar?.trim().isNotEmpty ?? false)
      ? site.jar!.trim()
      : (globalSpider?.trim() ?? '');

  if (_isScriptOfType(api, '.py') || _isScriptOfType(jar, '.py')) {
    return SpiderEngineType.py;
  }
  if (_isScriptOfType(api, '.js') || _isScriptOfType(jar, '.js')) {
    return SpiderEngineType.js;
  }
  return SpiderEngineType.jar;
}

bool _isScriptOfType(String value, String ext) {
  if (value.isEmpty) return false;
  final firstPart = value.split(';').first.trim();
  final uri = Uri.tryParse(firstPart);
  final path = (uri?.path ?? firstPart).toLowerCase();
  return path.endsWith(ext);
}

abstract class SpiderInstance {
  String get sourceKey;

  Future<Map<String, dynamic>> homeContent({bool filter = true});

  Future<Map<String, dynamic>> categoryContent(
    String categoryId, {
    int page = 1,
    bool filter = true,
    Map<String, dynamic>? extend,
  });

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
  String toString() {
    final d = detail?.trim();
    if (d == null || d.isEmpty) {
      return 'SpiderRuntimeException($code): $message';
    }
    return 'SpiderRuntimeException($code): $message\n$d';
  }
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

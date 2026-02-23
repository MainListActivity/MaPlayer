import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/core/spider/process/jar_direct_bridge.dart';

class JarSpiderExecutor implements SpiderExecutor {
  JarSpiderExecutor({SpiderTraceLogger? logger}) : _logger = logger;

  final SpiderTraceLogger? _logger;
  JarDirectBridge? _bridge;

  @override
  SpiderEngineType get type => SpiderEngineType.jar;

  @override
  Future<void> init(SpiderRuntimeSite site) async {
    _bridge ??= JarDirectBridge(site: site, logger: _logger);
    try {
      await _bridge!.invoke('init', <String, dynamic>{
        'sourceKey': site.sourceKey,
        'api': site.api,
        'ext': site.ext,
        'jar': site.jar,
      });
    } on SpiderRuntimeException catch (e) {
      _logger?.call(
        '[JarExecutor init failed] code=${e.code} detail=${e.detail}',
      );
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw SpiderRuntimeException('JAR executor is not initialized');
    }
    try {
      return await bridge.invoke(method, params);
    } on SpiderRuntimeException catch (e) {
      _logger?.call(
        '[JarExecutor invoke failed] method=$method code=${e.code} detail=${e.detail}',
      );
      rethrow;
    }
  }

  @override
  Future<void> destroy() async {
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) {
      try {
        await bridge.invoke('destroy', const <String, dynamic>{});
      } catch (_) {}
    }
  }
}

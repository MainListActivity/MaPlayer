import 'package:ma_palyer/core/spider/spider_asset_resolver.dart';
import 'package:ma_palyer/core/spider/process/jar_executor.dart';
import 'package:ma_palyer/core/spider/process/js_executor.dart';
import 'package:ma_palyer/core/spider/process/py_executor.dart';
import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/core/spider/spider_source_registry.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';

class SpiderRuntime {
  SpiderRuntime({
    SpiderSourceRegistry? registry,
    SpiderTraceLogger? logger,
    SpiderAssetResolver? assetResolver,
  }) : _registry = registry ?? SpiderSourceRegistry(),
       _logger = logger,
       _assetResolver = assetResolver ?? SpiderAssetResolver(logger: logger);

  final SpiderSourceRegistry _registry;
  final SpiderTraceLogger? _logger;
  final SpiderAssetResolver _assetResolver;

  final Map<String, _SpiderRuntimeInstance> _instances =
      <String, _SpiderRuntimeInstance>{};

  Future<SpiderInstance> getSpider(String sourceKey) async {
    final existed = _instances[sourceKey];
    if (existed != null) return existed;

    final config = await _registry.loadConfig();
    TvBoxSite? site;
    for (final item in config.sites) {
      if (item.key == sourceKey) {
        site = item;
        break;
      }
    }
    if (site == null) {
      throw SpiderRuntimeException(
        'Site not found for sourceKey=$sourceKey',
        code: 'SITE_NOT_FOUND',
      );
    }

    final runtimeSite = await _assetResolver.resolveRuntimeSite(
      site: site,
      sourceKey: sourceKey,
      globalSpider: config.spider,
    );

    final engine = _createExecutor(site, globalSpider: config.spider);
    await engine.init(runtimeSite);
    final instance = _SpiderRuntimeInstance(
      sourceKey: sourceKey,
      executor: engine,
      logger: _logger,
    );
    _instances[sourceKey] = instance;
    return instance;
  }

  Future<Object?> proxyLocal(Map<String, String> params) async {
    final sourceKey = params['sourceKey'];
    if (sourceKey == null || sourceKey.isEmpty) {
      throw SpiderRuntimeException(
        'proxyLocal requires sourceKey',
        code: 'SOURCE_KEY_REQUIRED',
      );
    }
    final spider = await getSpider(sourceKey);
    final runtime = spider as _SpiderRuntimeInstance;
    return runtime.executor.invoke('proxyLocal', <String, dynamic>{
      'params': params,
    });
  }

  Future<List<String>> vipFlags() => _registry.vipFlags();

  Future<void> dispose() async {
    for (final instance in _instances.values) {
      try {
        await instance.dispose();
      } catch (e) {
        _logger?.call('Spider instance dispose failed: $e');
      }
    }
    _instances.clear();
  }

  SpiderExecutor _createExecutor(TvBoxSite site, {String? globalSpider}) {
    final type = detectEngineFromSite(site, globalSpider: globalSpider);
    return switch (type) {
      SpiderEngineType.js => JsSpiderExecutor(logger: _logger),
      SpiderEngineType.jar => JarSpiderExecutor(logger: _logger),
      SpiderEngineType.py => PySpiderExecutor(logger: _logger),
    };
  }
}

class _SpiderRuntimeInstance implements SpiderInstance {
  _SpiderRuntimeInstance({
    required this.sourceKey,
    required this.executor,
    this.logger,
  });

  @override
  final String sourceKey;
  final SpiderTraceLogger? logger;

  final SpiderExecutor executor;

  @override
  Future<Map<String, dynamic>> homeContent({bool filter = true}) {
    return executor.invoke('homeContent', <String, dynamic>{'filter': filter});
  }

  @override
  Future<Map<String, dynamic>> categoryContent(
    String categoryId, {
    int page = 1,
    bool filter = true,
    Map<String, dynamic>? extend,
  }) {
    return executor.invoke('categoryContent', <String, dynamic>{
      'tid': categoryId,
      'pg': page.toString(),
      'filter': filter,
      'extend': extend ?? const <String, dynamic>{},
    });
  }

  @override
  Future<Map<String, dynamic>> detailContent(List<String> ids) {
    return executor.invoke('detailContent', <String, dynamic>{'ids': ids});
  }

  @override
  Future<Map<String, dynamic>> playerContent(
    String flag,
    String id,
    List<String> vipFlags,
  ) {
    return executor.invoke('playerContent', <String, dynamic>{
      'flag': flag,
      'id': id,
      'vipFlags': vipFlags,
    });
  }

  @override
  Future<Map<String, dynamic>> searchContent(String key, {bool quick = false}) {
    return executor.invoke('searchContent', <String, dynamic>{
      'key': key,
      'quick': quick,
    });
  }

  @override
  Future<void> dispose() async {
    try {
      await executor.destroy();
    } catch (e) {
      logger?.call('Spider executor destroy failed: $e');
    }
  }
}

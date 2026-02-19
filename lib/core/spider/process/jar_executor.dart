import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/core/spider/spider_process_manager.dart';
import 'package:ma_palyer/core/spider/spider_runtime_script_locator.dart';

class JarSpiderExecutor implements SpiderExecutor {
  JarSpiderExecutor({SpiderTraceLogger? logger}) : _logger = logger;

  final SpiderTraceLogger? _logger;
  SpiderProcessManager? _manager;

  @override
  SpiderEngineType get type => SpiderEngineType.jar;

  @override
  Future<void> init(SpiderRuntimeSite site) async {
    final scriptPath = await SpiderRuntimeScriptLocator.ensureScript(
      'run_jar.sh',
    );
    _manager ??= SpiderProcessManager(
      command: 'bash',
      arguments: <String>[scriptPath],
      logger: _logger,
    );
    await _manager!.call('init', <String, dynamic>{
      'sourceKey': site.sourceKey,
      'api': site.api,
      'ext': site.ext,
      'jar': site.jar,
    });
  }

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async {
    final manager = _manager;
    if (manager == null) {
      throw SpiderRuntimeException('JAR executor is not initialized');
    }
    return manager.call(method, params);
  }

  @override
  Future<void> destroy() async {
    await _manager?.call('destroy', const <String, dynamic>{});
    await _manager?.dispose();
    _manager = null;
  }
}

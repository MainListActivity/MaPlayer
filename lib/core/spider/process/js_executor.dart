import 'dart:io';

import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/core/spider/spider_process_manager.dart';

class JsSpiderExecutor implements SpiderExecutor {
  JsSpiderExecutor({SpiderTraceLogger? logger}) : _logger = logger;

  final SpiderTraceLogger? _logger;
  SpiderProcessManager? _manager;

  @override
  SpiderEngineType get type => SpiderEngineType.js;

  @override
  Future<void> init(SpiderRuntimeSite site) async {
    _manager ??= SpiderProcessManager(
      command: 'bash',
      arguments: <String>[_scriptPath('run_js.sh')],
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
      throw SpiderRuntimeException('JS executor is not initialized');
    }
    return manager.call(method, params);
  }

  @override
  Future<void> destroy() async {
    await _manager?.call('destroy', const <String, dynamic>{});
    await _manager?.dispose();
    _manager = null;
  }

  String _scriptPath(String scriptName) {
    return '${Directory.current.path}/tool/spider_runtime/$scriptName';
  }
}

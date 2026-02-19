import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/core/spider/process/jar_direct_bridge.dart';
import 'package:ma_palyer/core/spider/spider_engine.dart';

SpiderRuntimeSite _siteWithJar(String jarPath) {
  return SpiderRuntimeSite(
    sourceKey: 'demo',
    api: 'csp_Demo',
    ext: '',
    jar: jarPath,
  );
}

void main() {
  test('bridge failure detail includes command and stdio', () async {
    final logs = <String>[];
    final jarFile = File(
      '${Directory.systemTemp.path}/jar-bridge-test-${DateTime.now().microsecondsSinceEpoch}.jar',
    );
    await jarFile.writeAsBytes(const <int>[1], flush: true);
    addTearDown(() async {
      if (jarFile.existsSync()) {
        await jarFile.delete();
      }
    });

    final bridge = JarDirectBridge(
      site: _siteWithJar(jarFile.path),
      logger: logs.add,
      processRunner: (exe, args) async {
        return ProcessResult(100, 1, 'bad out', 'bad err');
      },
    );

    try {
      await bridge.invoke('init', const <String, dynamic>{});
      fail('expected exception');
    } on SpiderRuntimeException catch (e) {
      expect(e.code, 'JAR_BRIDGE_FAILED');
      expect(e.detail, isNotNull);
      expect(e.detail!, contains('command='));
      expect(e.detail!, contains('stdout=bad out'));
      expect(e.detail!, contains('stderr=bad err'));
      expect(e.detail!, contains('method=init'));
    }
    expect(logs.any((m) => m.contains('[JarBridgeError]')), isTrue);
  });

  test('bridge runtime error from stdout is preserved in detail', () async {
    final jarFile = File(
      '${Directory.systemTemp.path}/jar-bridge-test-${DateTime.now().microsecondsSinceEpoch}.jar',
    );
    await jarFile.writeAsBytes(const <int>[1], flush: true);
    addTearDown(() async {
      if (jarFile.existsSync()) {
        await jarFile.delete();
      }
    });

    final bridge = JarDirectBridge(
      site: _siteWithJar(jarFile.path),
      processRunner: (exe, args) async {
        return ProcessResult(
          101,
          0,
          '{"error":{"code":"RUNTIME_ERROR","message":"boom"}}',
          '',
        );
      },
    );

    try {
      await bridge.invoke('init', const <String, dynamic>{});
      fail('expected exception');
    } on SpiderRuntimeException catch (e) {
      expect(e.code, 'RUNTIME_ERROR');
      expect(e.message, 'boom');
      expect(e.detail, isNotNull);
      expect(e.detail!, contains('stdout='));
      expect(e.detail!, contains('"message":"boom"'));
    }
  });

  test('spawn failure is mapped to JAR_BRIDGE_SPAWN_FAILED', () async {
    final logs = <String>[];
    final jarFile = File(
      '${Directory.systemTemp.path}/jar-bridge-test-${DateTime.now().microsecondsSinceEpoch}.jar',
    );
    await jarFile.writeAsBytes(const <int>[1], flush: true);
    addTearDown(() async {
      if (jarFile.existsSync()) {
        await jarFile.delete();
      }
    });

    final bridge = JarDirectBridge(
      site: _siteWithJar(jarFile.path),
      logger: logs.add,
      processRunner: (exe, args) async {
        throw ProcessException(
          exe,
          args,
          'Operation not permitted',
          1,
        );
      },
    );

    try {
      await bridge.invoke('init', const <String, dynamic>{});
      fail('expected exception');
    } on SpiderRuntimeException catch (e) {
      expect(e.code, 'JAR_BRIDGE_SPAWN_FAILED');
      expect(e.detail, isNotNull);
      expect(e.detail!, contains('Operation not permitted'));
      expect(e.detail!, contains('command='));
      expect(e.detail!, contains('sandboxed='));
    }
    expect(logs.any((m) => m.contains('[JarBridgeSpawnError]')), isTrue);
  });

  test('dex-only spider archive is rejected with clear error', () async {
    final jarFile = File(
      '${Directory.systemTemp.path}/jar-bridge-test-${DateTime.now().microsecondsSinceEpoch}.jar',
    );
    await jarFile.writeAsString('PK__classes.dex__assets/wexguard_v8.so__');
    addTearDown(() async {
      if (jarFile.existsSync()) {
        await jarFile.delete();
      }
    });

    final bridge = JarDirectBridge(site: _siteWithJar(jarFile.path));
    try {
      await bridge.invoke('init', const <String, dynamic>{});
      fail('expected exception');
    } on SpiderRuntimeException catch (e) {
      expect(e.code, 'JAR_DEX_UNSUPPORTED');
      expect(e.detail, isNotNull);
      expect(e.detail!, contains('classes.dex-only'));
    }
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:ma_palyer/core/spider/spider_engine.dart';

typedef JarBridgeProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class JarDirectBridge {
  JarDirectBridge({
    required this.site,
    this.logger,
    JarBridgeProcessRunner? processRunner,
  }) : _processRunner = processRunner ?? _defaultProcessRunner;

  final SpiderRuntimeSite site;
  final SpiderTraceLogger? logger;
  final JarBridgeProcessRunner _processRunner;

  static const String _bridgeRelPath = 'BridgeMain.java';

  static const String _bridgeSource = r'''
import java.io.PrintWriter;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class BridgeMain {
  private static final char SEP = 31;

  public static void main(String[] args) {
    try {
      if (args.length < 4) fail("INVALID_ARGS", "Expected 4 arguments: api, extB64, method, payloadB64");
      final String api = args[0];
      final String ext = new String(java.util.Base64.getDecoder().decode(args[1]), java.nio.charset.StandardCharsets.UTF_8);
      final String method = args[2];
      final String payload = new String(java.util.Base64.getDecoder().decode(args[3]), java.nio.charset.StandardCharsets.UTF_8);

      final String clsKey = api.startsWith("csp_") ? api.substring(4) : api;
      final String spiderClsName = "com.github.catvod.spider." + clsKey;
      final Class<?> spiderCls = Class.forName(spiderClsName);
      final Object spider = spiderCls.getDeclaredConstructor().newInstance();
      invokeInit(spiderCls, spider, ext);

      switch (method) {
        case "init":
          ok("{\"ok\":true}");
          return;
        case "homeContent":
          printString((String) spiderCls.getMethod("homeContent", boolean.class).invoke(spider, parseBool(payload)));
          return;
        case "categoryContent":
          doCategory(spiderCls, spider, payload);
          return;
        case "detailContent":
          doDetail(spiderCls, spider, payload);
          return;
        case "searchContent":
          doSearch(spiderCls, spider, payload);
          return;
        case "playerContent":
          doPlayer(spiderCls, spider, payload);
          return;
        case "proxyLocal":
          doProxy(spiderCls, spider, payload);
          return;
        case "destroy":
          invokeDestroyQuietly(spiderCls, spider);
          ok("{\"ok\":true}");
          return;
        default:
          fail("UNSUPPORTED_METHOD", method);
      }
    } catch (Throwable t) {
      fail("RUNTIME_ERROR", t.toString());
    }
  }

  private static void invokeInit(Class<?> spiderCls, Object spider, String ext) throws Exception {
    Method[] methods = spiderCls.getMethods();
    for (Method m : methods) {
      if (!"init".equals(m.getName())) continue;
      int n = m.getParameterCount();
      if (n == 2) {
        m.invoke(spider, null, ext == null ? "" : ext);
        return;
      }
    }
    for (Method m : methods) {
      if (!"init".equals(m.getName())) continue;
      if (m.getParameterCount() == 1) {
        m.invoke(spider, new Object[] { null });
        return;
      }
    }
  }

  private static void invokeDestroyQuietly(Class<?> spiderCls, Object spider) {
    try {
      Method m = spiderCls.getMethod("destroy");
      m.invoke(spider);
    } catch (Throwable ignored) {}
  }

  private static void doCategory(Class<?> spiderCls, Object spider, String payload) throws Exception {
    String[] parts = split(payload);
    String tid = parts.length > 0 ? parts[0] : "";
    String pg = parts.length > 1 ? parts[1] : "1";
    boolean filter = parts.length > 2 && parseBool(parts[2]);
    HashMap<String, String> extMap = parseMap(parts.length > 3 ? parts[3] : "");
    Object ret = spiderCls.getMethod("categoryContent", String.class, String.class, boolean.class, HashMap.class)
        .invoke(spider, tid, pg, filter, extMap);
    printString((String) ret);
  }

  private static void doDetail(Class<?> spiderCls, Object spider, String payload) throws Exception {
    String[] parts = split(payload);
    List<String> ids = new ArrayList<>();
    for (String p : parts) if (!p.isEmpty()) ids.add(p);
    Object ret = spiderCls.getMethod("detailContent", List.class).invoke(spider, ids);
    printString((String) ret);
  }

  private static void doSearch(Class<?> spiderCls, Object spider, String payload) throws Exception {
    String[] parts = split(payload);
    String key = parts.length > 0 ? parts[0] : "";
    boolean quick = parts.length > 1 && parseBool(parts[1]);
    Object ret = spiderCls.getMethod("searchContent", String.class, boolean.class).invoke(spider, key, quick);
    printString((String) ret);
  }

  private static void doPlayer(Class<?> spiderCls, Object spider, String payload) throws Exception {
    String[] parts = split(payload);
    String flag = parts.length > 0 ? parts[0] : "";
    String id = parts.length > 1 ? parts[1] : "";
    List<String> vip = new ArrayList<>();
    for (int i = 2; i < parts.length; i++) if (!parts[i].isEmpty()) vip.add(parts[i]);
    Object ret = spiderCls.getMethod("playerContent", String.class, String.class, List.class).invoke(spider, flag, id, vip);
    printString((String) ret);
  }

  private static void doProxy(Class<?> spiderCls, Object spider, String payload) throws Exception {
    HashMap<String, String> params = parseMap(payload);
    Object ret = spiderCls.getMethod("proxyLocal", Map.class).invoke(spider, params);
    if (!(ret instanceof Object[])) {
      ok("{\"value\":null}");
      return;
    }
    Object[] arr = (Object[]) ret;
    StringBuilder sb = new StringBuilder();
    sb.append("{\"value\":[");
    for (int i = 0; i < arr.length; i++) {
      if (i > 0) sb.append(",");
      Object v = arr[i];
      if (v == null) {
        sb.append("null");
      } else if (v instanceof Number || v instanceof Boolean) {
        sb.append(v.toString());
      } else {
        sb.append("\"").append(escape(v.toString())).append("\"");
      }
    }
    sb.append("]}");
    ok(sb.toString());
  }

  private static String[] split(String payload) {
    return payload.split(String.valueOf(SEP), -1);
  }

  private static boolean parseBool(String value) {
    return "1".equals(value) || "true".equalsIgnoreCase(value);
  }

  private static HashMap<String, String> parseMap(String text) {
    HashMap<String, String> out = new HashMap<>();
    if (text == null || text.isEmpty()) return out;
    String[] lines = text.split("\\n", -1);
    for (String line : lines) {
      if (line == null || line.isEmpty()) continue;
      int idx = line.indexOf('\t');
      if (idx <= 0) continue;
      String k = line.substring(0, idx);
      String v = line.substring(idx + 1);
      out.put(k, v);
    }
    return out;
  }

  private static void printString(String value) {
    if (value == null || value.trim().isEmpty()) {
      ok("{}");
      return;
    }
    ok(value.trim());
  }

  private static void ok(String body) {
    PrintWriter out = new PrintWriter(System.out);
    out.print(body);
    out.flush();
  }

  private static String escape(String s) {
    return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
  }

  private static void fail(String code, String message) {
    String body = "{\"error\":{\"code\":\"" + escape(code) + "\",\"message\":\"" + escape(message) + "\"}}";
    ok(body);
    System.exit(1);
  }
}
''';

  Future<void> ensureReady() async {
    final jarFile = File(site.jar);
    if (!jarFile.existsSync()) {
      throw SpiderRuntimeException(
        'JAR not found: ${site.jar}',
        code: 'JAR_NOT_FOUND',
      );
    }
    await _validateJarCompatibility(jarFile);
    final dir = await _ensureRuntimeDir();
    await _ensureSourceFile(dir, _bridgeRelPath, _bridgeSource);
  }

  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async {
    await ensureReady();
    final runtimeDir = await _ensureRuntimeDir();
    final bridgeFile = '${runtimeDir.path}/$_bridgeRelPath';
    final java = await _resolveJavaTool('java');
    final payload = _encodePayload(method, params);
    final args = <String>[
      '--class-path',
      site.jar,
      bridgeFile,
      site.api,
      base64.encode(utf8.encode(site.ext)),
      method,
      base64.encode(utf8.encode(payload)),
    ];
    ProcessResult result;
    try {
      result = await _processRunner(java, args);
    } on ProcessException catch (e) {
      final detail = _spawnFailureDetail(
        method: method,
        java: java,
        args: args,
        error: e,
      );
      logger?.call('[JarBridgeSpawnError] $detail');
      throw SpiderRuntimeException(
        'Java process spawn failed for method=$method',
        code: 'JAR_BRIDGE_SPAWN_FAILED',
        detail: detail,
      );
    }
    final stdout = (result.stdout ?? '').toString().trim();
    final stderr = (result.stderr ?? '').toString().trim();
    if (result.exitCode != 0) {
      final detail = _failureDetail(
        method: method,
        java: java,
        exitCode: result.exitCode,
        stdout: stdout,
        stderr: stderr,
      );
      logger?.call('[JarBridgeError] $detail');
      throw SpiderRuntimeException(
        'Java bridge failed for method=$method',
        code: 'JAR_BRIDGE_FAILED',
        detail: detail,
      );
    }
    if (stdout.isEmpty) return <String, dynamic>{};
    dynamic decoded;
    try {
      decoded = jsonDecode(stdout);
    } catch (_) {
      return <String, dynamic>{'value': stdout};
    }
    if (decoded is Map<String, dynamic>) {
      final err = decoded['error'];
      if (err is Map) {
        final code = err['code']?.toString();
        final message =
            err['message']?.toString() ?? 'JAR bridge runtime error';
        final detail =
            'method=$method api=${site.api} jar=${site.jar}\nstdout=$stdout';
        logger?.call('[JarBridgeRuntimeError] code=$code message=$message');
        throw SpiderRuntimeException(message, code: code, detail: detail);
      }
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return <String, dynamic>{'value': decoded};
  }

  String _encodePayload(String method, Map<String, dynamic> params) {
    const sep = '\u001f';
    switch (method) {
      case 'init':
      case 'destroy':
        return '';
      case 'homeContent':
        return _boolToken(params['filter']);
      case 'categoryContent':
        final tid = (params['tid'] ?? '').toString();
        final pg = (params['pg'] ?? '1').toString();
        final filter = _boolToken(params['filter']);
        final extendMap = (params['extend'] is Map)
            ? Map<String, dynamic>.from(params['extend'] as Map)
            : const <String, dynamic>{};
        final extLines = extendMap.entries
            .map((e) => '${e.key}\t${e.value ?? ''}')
            .join('\n');
        return '$tid$sep$pg$sep$filter$sep$extLines';
      case 'detailContent':
        final ids = (params['ids'] is List)
            ? params['ids'] as List
            : <dynamic>[];
        return ids.map((e) => e.toString()).join(sep);
      case 'searchContent':
        final key = (params['key'] ?? '').toString();
        final quick = _boolToken(params['quick']);
        return '$key$sep$quick';
      case 'playerContent':
        final flag = (params['flag'] ?? '').toString();
        final id = (params['id'] ?? '').toString();
        final vip = (params['vipFlags'] is List)
            ? (params['vipFlags'] as List).map((e) => e.toString()).toList()
            : const <String>[];
        return <String>[flag, id, ...vip].join(sep);
      case 'proxyLocal':
        return params.entries
            .map((e) => '${e.key}\t${e.value ?? ''}')
            .join('\n');
      default:
        return '';
    }
  }

  String _boolToken(dynamic value) {
    if (value is bool) return value ? '1' : '0';
    if (value == null) return '0';
    final text = value.toString().toLowerCase();
    return (text == '1' || text == 'true') ? '1' : '0';
  }

  Future<String> _resolveJavaTool(String name) async {
    final candidates = <String>[];
    final envBin = Platform.environment['MA_PLAYER_JAVA_BIN']?.trim();
    if (envBin != null && envBin.isNotEmpty) {
      candidates.add(envBin);
    }

    final javaHomeEnv = Platform.environment['JAVA_HOME']?.trim();
    if (javaHomeEnv != null && javaHomeEnv.isNotEmpty) {
      candidates.add('$javaHomeEnv/bin/$name');
    }

    final commonHomes = <String>[
      '/opt/homebrew/opt/openjdk',
      '/usr/local/opt/openjdk',
      '/Library/Java/JavaVirtualMachines',
    ];
    for (final home in commonHomes) {
      final dir = Directory(home);
      if (!dir.existsSync()) continue;
      if (home.endsWith('/JavaVirtualMachines')) {
        for (final child in dir.listSync(followLinks: false)) {
          if (child is Directory) {
            candidates.add('${child.path}/Contents/Home/bin/$name');
          }
        }
      } else {
        candidates.add('$home/bin/$name');
      }
    }

    final whichResult = await Process.run('which', <String>[name]);
    if (whichResult.exitCode == 0) {
      final whichPath = (whichResult.stdout ?? '').toString().trim();
      if (whichPath.isNotEmpty) {
        candidates.add(whichPath);
      }
    }

    final fallback = '/usr/bin/$name';
    candidates.add(fallback);

    final tried = <String>[];
    for (final candidate in candidates.toSet()) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      tried.add(candidate);
      final check = await Process.run(candidate, <String>['-version']);
      if (check.exitCode == 0) {
        return candidate;
      }
      final err = (check.stderr ?? '').toString().trim();
      if (err.isNotEmpty) {
        logger?.call('[JarBridgeJavaProbe] path=$candidate failed: $err');
      }
    }

    logger?.call('[JarBridgeJavaProbe] searched=${candidates.join(',')}');
    throw SpiderRuntimeException(
      '$name not found',
      code: 'JAVA_TOOL_NOT_FOUND',
      detail: 'searched=${tried.join(',')}',
    );
  }

  Future<void> _validateJarCompatibility(File jarFile) async {
    try {
      final bytes = await jarFile.readAsBytes();
      final text = latin1.decode(bytes, allowInvalid: true);
      final hasDex = text.contains('classes.dex');
      final hasClassEntries = text.contains('.class');
      if (hasDex && !hasClassEntries) {
        throw SpiderRuntimeException(
          'Unsupported spider archive format: Android DEX package',
          code: 'JAR_DEX_UNSUPPORTED',
          detail:
              'jar=${jarFile.path}\n'
              'detected=classes.dex-only\n'
              'hint=This spider package is built for Android DexClassLoader and cannot run with desktop JVM reflection.',
        );
      }
    } on SpiderRuntimeException {
      rethrow;
    } catch (_) {
      // Best-effort validation only.
    }
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }

  String _failureDetail({
    required String method,
    required String java,
    required int exitCode,
    required String stdout,
    required String stderr,
  }) {
    final command = <String>[
      java,
      '--class-path',
      site.jar,
      '<bridge.java>',
      site.api,
      '<ext:b64>',
      method,
      '<payload:b64>',
    ].join(' ');
    final stdoutText = stdout.isEmpty ? '<empty>' : stdout;
    final stderrText = stderr.isEmpty ? '<empty>' : stderr;
    return 'method=$method api=${site.api} jar=${site.jar}\n'
        'command=$command\n'
        'exitCode=$exitCode\n'
        'stdout=$stdoutText\n'
        'stderr=$stderrText';
  }

  String _spawnFailureDetail({
    required String method,
    required String java,
    required List<String> args,
    required ProcessException error,
  }) {
    final sandboxed = Platform.environment.containsKey(
      'APP_SANDBOX_CONTAINER_ID',
    );
    final command = <String>[
      java,
      '--class-path',
      site.jar,
      '<bridge.java>',
      site.api,
      '<ext:b64>',
      method,
      '<payload:b64>',
    ].join(' ');
    return 'method=$method api=${site.api} jar=${site.jar}\n'
        'command=$command\n'
        'error=${error.message}\n'
        'errorCode=${error.errorCode}\n'
        'exception=${error.toString()}\n'
        'sandboxed=$sandboxed\n'
        'hint=${sandboxed ? 'macOS App Sandbox blocks spawning external java in current setup; disable sandbox for Debug/Profile in macos/Runner/DebugProfile.entitlements' : 'check java path/permissions'}';
  }

  Future<void> _ensureSourceFile(
    Directory dir,
    String relPath,
    String source,
  ) async {
    final file = File('${dir.path}/$relPath');
    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    if (!file.existsSync() || await file.readAsString() != source) {
      await file.writeAsString(source, flush: true);
    }
  }

  static Directory? _cachedRuntimeDir;

  Future<Directory> _ensureRuntimeDir() async {
    final cached = _cachedRuntimeDir;
    if (cached != null && cached.existsSync()) return cached;
    final dir = Directory(
      '${Directory.systemTemp.path}/ma_player_spider_java_bridge',
    );
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _cachedRuntimeDir = dir;
    return dir;
  }
}

import 'dart:convert';

import 'package:ma_palyer/tvbox/tvbox_ext_resolver.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';
import 'package:ma_palyer/tvbox/tvbox_normalizers.dart';
import 'package:ma_palyer/tvbox/tvbox_parse_report.dart';
import 'package:ma_palyer/tvbox/tvbox_source_resolver.dart';

class TvBoxParser {
  TvBoxParser({
    TvBoxSourceResolver? sourceResolver,
    int maxDepth = 8,
    int maxNodes = 200,
    Duration? requestTimeout,
  }) : _extResolver = TvBoxExtResolver(
         sourceResolver: sourceResolver ?? const DefaultTvBoxSourceResolver(),
         maxDepth: maxDepth,
         maxNodes: maxNodes,
         requestTimeout: requestTimeout,
       );

  final TvBoxExtResolver _extResolver;

  Future<TvBoxParseReport> parseString(String source, {Uri? baseUri}) async {
    final issues = <TvBoxIssue>[];
    late final TvBoxIssueSink issueSink;
    issueSink = (level, code, path, message, {rawValue}) {
      issues.add(
        TvBoxIssue(
          code: code,
          path: path,
          level: level,
          message: message,
          rawValue: rawValue,
        ),
      );
    };

    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } catch (e) {
      issueSink(
        TvBoxIssueLevel.fatal,
        'TVB_JSON_SYNTAX',
        r'$',
        'JSON 语法错误: $e',
      );
      return TvBoxParseReport(config: null, issues: issues);
    }
    if (decoded is! Map) {
      issueSink(
        TvBoxIssueLevel.fatal,
        'TVB_JSON_ROOT_NOT_OBJECT',
        r'$',
        'TVBox 配置根节点必须是 object。',
      );
      return TvBoxParseReport(config: null, issues: issues);
    }

    return parseMap(Map<String, dynamic>.from(decoded), baseUri: baseUri);
  }

  Future<TvBoxParseReport> parseMap(Map<String, dynamic> map, {Uri? baseUri}) async {
    final issues = <TvBoxIssue>[];
    void issueSink(
      TvBoxIssueLevel level,
      String code,
      String path,
      String message, {
      Object? rawValue,
    }) {
      issues.add(
        TvBoxIssue(
          code: code,
          path: path,
          level: level,
          message: message,
          rawValue: rawValue,
        ),
      );
    }

    _extResolver.reset();
    final rawRoot = Map<String, dynamic>.from(map);
    Map<String, dynamic>? resolvedRootExt;
    final rootExt = rawRoot['ext'];
    if (rootExt is String && rootExt.trim().isNotEmpty) {
      resolvedRootExt = await _extResolver.resolveExtToMap(
        extValue: rootExt,
        path: r'$.ext',
        baseUri: baseUri,
        issueSink: issueSink,
      );
    }

    final mergedRoot = resolvedRootExt == null
        ? rawRoot
        : _mergeMapPreferLocal(resolvedRootExt, rawRoot);

    final sites = await _parseSites(mergedRoot['sites'], issueSink, baseUri);
    final lives = await _parseLives(mergedRoot['lives'], issueSink, baseUri);
    final parses = await _parseParses(mergedRoot['parses'], issueSink, baseUri);
    final drives = await _parseDrives(mergedRoot['drives'], issueSink, baseUri);
    final rules = _parseRules(mergedRoot['rules'], issueSink);
    final player = _parsePlayer(mergedRoot['player'], issueSink);

    final config = TvBoxConfig(
      raw: mergedRoot,
      extras: _extrasFromRoot(mergedRoot),
      spider: TvBoxNormalizers.asString(
        mergedRoot['spider'],
        path: r'$.spider',
        issueSink: issueSink,
      ),
      wallpaper: TvBoxNormalizers.asString(
        mergedRoot['wallpaper'],
        path: r'$.wallpaper',
        issueSink: issueSink,
      ),
      logo: TvBoxNormalizers.asString(
        mergedRoot['logo'],
        path: r'$.logo',
        issueSink: issueSink,
      ),
      sites: sites,
      lives: lives,
      parses: parses,
      flags: TvBoxNormalizers.asStringList(
        mergedRoot['flags'],
        path: r'$.flags',
        issueSink: issueSink,
      ),
      ijk: TvBoxNormalizers.asMap(
        mergedRoot['ijk'],
        path: r'$.ijk',
        issueSink: issueSink,
      ),
      ads: mergedRoot['ads'] is List ? List<dynamic>.from(mergedRoot['ads'] as List) : null,
      drives: drives,
      rules: rules,
      player: player,
      cache: TvBoxNormalizers.asMap(
        mergedRoot['cache'],
        path: r'$.cache',
        issueSink: issueSink,
      ),
      proxy: TvBoxNormalizers.asMap(
        mergedRoot['proxy'],
        path: r'$.proxy',
        issueSink: issueSink,
      ),
      dns: TvBoxNormalizers.asMap(
        mergedRoot['dns'],
        path: r'$.dns',
        issueSink: issueSink,
      ),
      headers: TvBoxNormalizers.asMap(
        mergedRoot['headers'],
        path: r'$.headers',
        issueSink: issueSink,
      ),
      ua: TvBoxNormalizers.asString(
        mergedRoot['ua'],
        path: r'$.ua',
        issueSink: issueSink,
      ),
      timeout: TvBoxNormalizers.asInt(
        mergedRoot['timeout'],
        path: r'$.timeout',
        issueSink: issueSink,
      ),
      recommend: mergedRoot['recommend'],
      hotSearch: mergedRoot['hotSearch'],
      ext: mergedRoot['ext'],
      resolvedExtRaw: resolvedRootExt,
    );

    if (mergedRoot['ads'] != null && mergedRoot['ads'] is! List) {
      issueSink(
        TvBoxIssueLevel.warning,
        'TVB_TYPE_ADS_LIST',
        r'$.ads',
        'ads 字段期望数组。',
        rawValue: mergedRoot['ads'],
      );
    }

    return TvBoxParseReport(config: config, issues: issues);
  }

  Future<TvBoxConfig> parseStringOrThrow(String source, {Uri? baseUri}) async {
    final report = await parseString(source, baseUri: baseUri);
    if (report.hasFatalError || report.config == null) {
      throw const FormatException('TVBox 配置存在致命错误，无法解析。');
    }
    return report.config!;
  }

  Future<List<TvBoxSite>> _parseSites(
    dynamic raw,
    TvBoxIssueSink issueSink,
    Uri? baseUri,
  ) async {
    final maps = TvBoxNormalizers.asMapList(
      raw,
      path: r'$.sites',
      issueSink: issueSink,
    );
    final result = <TvBoxSite>[];

    for (var i = 0; i < maps.length; i++) {
      final siteMap = maps[i];
      final path = '\$.sites[$i]';
      Map<String, dynamic>? resolvedExt;
      if (siteMap['ext'] is String && (siteMap['ext'] as String).trim().isNotEmpty) {
        resolvedExt = await _extResolver.resolveExtToMap(
          extValue: siteMap['ext'],
          path: '$path.ext',
          baseUri: baseUri,
          issueSink: issueSink,
        );
      }

      final key = TvBoxNormalizers.asString(
            siteMap['key'],
            path: '$path.key',
            issueSink: issueSink,
          ) ??
          '';
      final name = TvBoxNormalizers.asString(
            siteMap['name'],
            path: '$path.name',
            issueSink: issueSink,
          ) ??
          '';
      if (key.isEmpty && name.isEmpty) {
        issueSink(
          TvBoxIssueLevel.warning,
          'TVB_REQUIRED_SITE_KEY_OR_NAME',
          path,
          'site 至少需要 key 或 name，当前项已丢弃。',
          rawValue: siteMap,
        );
        continue;
      }

      result.add(
        TvBoxSite(
          raw: siteMap,
          extras: _extrasFromMap(
            siteMap,
            const {
              'key',
              'name',
              'type',
              'api',
              'searchable',
              'quickSearch',
              'filterable',
              'changeable',
              'playUrl',
              'ext',
              'jar',
              'categories',
              'style',
            },
          ),
          key: key,
          name: name,
          api: TvBoxNormalizers.asString(
            siteMap['api'],
            path: '$path.api',
            issueSink: issueSink,
          ),
          type: TvBoxNormalizers.asInt(
            siteMap['type'],
            path: '$path.type',
            issueSink: issueSink,
          ),
          ext: siteMap['ext'],
          resolvedExtRaw: resolvedExt,
          searchable: TvBoxNormalizers.asInt(
            siteMap['searchable'],
            path: '$path.searchable',
            issueSink: issueSink,
          ),
          quickSearch: TvBoxNormalizers.asInt(
            siteMap['quickSearch'],
            path: '$path.quickSearch',
            issueSink: issueSink,
          ),
          filterable: TvBoxNormalizers.asInt(
            siteMap['filterable'],
            path: '$path.filterable',
            issueSink: issueSink,
          ),
          changeable: TvBoxNormalizers.asInt(
            siteMap['changeable'],
            path: '$path.changeable',
            issueSink: issueSink,
          ),
          playUrl: TvBoxNormalizers.asString(
            siteMap['playUrl'],
            path: '$path.playUrl',
            issueSink: issueSink,
          ),
          jar: TvBoxNormalizers.asString(
            siteMap['jar'],
            path: '$path.jar',
            issueSink: issueSink,
          ),
          categories: TvBoxNormalizers.asStringList(
            siteMap['categories'],
            path: '$path.categories',
            issueSink: issueSink,
          ),
          style: siteMap['style'],
        ),
      );
    }
    return result;
  }

  Future<List<TvBoxLive>> _parseLives(
    dynamic raw,
    TvBoxIssueSink issueSink,
    Uri? baseUri,
  ) async {
    final maps = TvBoxNormalizers.asMapList(
      raw,
      path: r'$.lives',
      issueSink: issueSink,
    );
    final result = <TvBoxLive>[];
    for (var i = 0; i < maps.length; i++) {
      final liveMap = maps[i];
      final path = '\$.lives[$i]';
      Map<String, dynamic>? resolvedExt;
      if (liveMap['ext'] is String && (liveMap['ext'] as String).trim().isNotEmpty) {
        resolvedExt = await _extResolver.resolveExtToMap(
          extValue: liveMap['ext'],
          path: '$path.ext',
          baseUri: baseUri,
          issueSink: issueSink,
        );
      }
      result.add(
        TvBoxLive(
          raw: liveMap,
          extras: _extrasFromMap(
            liveMap,
            const {'name', 'url', 'type', 'ua', 'epg', 'logo', 'header', 'ext'},
          ),
          name: TvBoxNormalizers.asString(
            liveMap['name'],
            path: '$path.name',
            issueSink: issueSink,
          ),
          url: TvBoxNormalizers.asString(
            liveMap['url'],
            path: '$path.url',
            issueSink: issueSink,
          ),
          type: TvBoxNormalizers.asInt(
            liveMap['type'],
            path: '$path.type',
            issueSink: issueSink,
          ),
          ua: TvBoxNormalizers.asString(
            liveMap['ua'],
            path: '$path.ua',
            issueSink: issueSink,
          ),
          epg: TvBoxNormalizers.asString(
            liveMap['epg'],
            path: '$path.epg',
            issueSink: issueSink,
          ),
          logo: TvBoxNormalizers.asString(
            liveMap['logo'],
            path: '$path.logo',
            issueSink: issueSink,
          ),
          header: TvBoxNormalizers.asMap(
            liveMap['header'],
            path: '$path.header',
            issueSink: issueSink,
          ),
          ext: liveMap['ext'],
          resolvedExtRaw: resolvedExt,
        ),
      );
    }
    return result;
  }

  Future<List<TvBoxParse>> _parseParses(
    dynamic raw,
    TvBoxIssueSink issueSink,
    Uri? baseUri,
  ) async {
    final maps = TvBoxNormalizers.asMapList(
      raw,
      path: r'$.parses',
      issueSink: issueSink,
    );
    final result = <TvBoxParse>[];
    for (var i = 0; i < maps.length; i++) {
      final parseMap = maps[i];
      final path = '\$.parses[$i]';
      Map<String, dynamic>? resolvedExt;
      if (parseMap['ext'] is String && (parseMap['ext'] as String).trim().isNotEmpty) {
        resolvedExt = await _extResolver.resolveExtToMap(
          extValue: parseMap['ext'],
          path: '$path.ext',
          baseUri: baseUri,
          issueSink: issueSink,
        );
      }

      result.add(
        TvBoxParse(
          raw: parseMap,
          extras: _extrasFromMap(
            parseMap,
            const {'name', 'url', 'type', 'ext', 'header', 'priority', 'web', 'flag'},
          ),
          name: TvBoxNormalizers.asString(
            parseMap['name'],
            path: '$path.name',
            issueSink: issueSink,
          ),
          url: TvBoxNormalizers.asString(
            parseMap['url'],
            path: '$path.url',
            issueSink: issueSink,
          ),
          type: TvBoxNormalizers.asInt(
            parseMap['type'],
            path: '$path.type',
            issueSink: issueSink,
          ),
          ext: parseMap['ext'],
          resolvedExtRaw: resolvedExt,
          header: TvBoxNormalizers.asMap(
            parseMap['header'],
            path: '$path.header',
            issueSink: issueSink,
          ),
          priority: TvBoxNormalizers.asInt(
            parseMap['priority'],
            path: '$path.priority',
            issueSink: issueSink,
          ),
          web: TvBoxNormalizers.asBool(
            parseMap['web'],
            path: '$path.web',
            issueSink: issueSink,
          ),
          flag: TvBoxNormalizers.asString(
            parseMap['flag'],
            path: '$path.flag',
            issueSink: issueSink,
          ),
        ),
      );
    }
    return result;
  }

  Future<List<TvBoxDrive>> _parseDrives(
    dynamic raw,
    TvBoxIssueSink issueSink,
    Uri? baseUri,
  ) async {
    final maps = TvBoxNormalizers.asMapList(
      raw,
      path: r'$.drives',
      issueSink: issueSink,
    );
    final result = <TvBoxDrive>[];
    for (var i = 0; i < maps.length; i++) {
      final driveMap = maps[i];
      final path = '\$.drives[$i]';
      Map<String, dynamic>? resolvedExt;
      if (driveMap['ext'] is String && (driveMap['ext'] as String).trim().isNotEmpty) {
        resolvedExt = await _extResolver.resolveExtToMap(
          extValue: driveMap['ext'],
          path: '$path.ext',
          baseUri: baseUri,
          issueSink: issueSink,
        );
      }

      result.add(
        TvBoxDrive(
          raw: driveMap,
          extras: _extrasFromMap(
            driveMap,
            const {'provider', 'key', 'name', 'api', 'ext'},
          ),
          provider: TvBoxNormalizers.asString(
            driveMap['provider'],
            path: '$path.provider',
            issueSink: issueSink,
          ),
          key: TvBoxNormalizers.asString(
            driveMap['key'],
            path: '$path.key',
            issueSink: issueSink,
          ),
          name: TvBoxNormalizers.asString(
            driveMap['name'],
            path: '$path.name',
            issueSink: issueSink,
          ),
          api: TvBoxNormalizers.asString(
            driveMap['api'],
            path: '$path.api',
            issueSink: issueSink,
          ),
          ext: driveMap['ext'],
          resolvedExtRaw: resolvedExt,
        ),
      );
    }
    return result;
  }

  List<TvBoxRule> _parseRules(dynamic raw, TvBoxIssueSink issueSink) {
    final maps = TvBoxNormalizers.asMapList(
      raw,
      path: r'$.rules',
      issueSink: issueSink,
    );
    final result = <TvBoxRule>[];
    for (var i = 0; i < maps.length; i++) {
      final ruleMap = maps[i];
      final path = '\$.rules[$i]';
      result.add(
        TvBoxRule(
          raw: ruleMap,
          extras: _extrasFromMap(ruleMap, const {'enable', 'match', 'replace', 'priority'}),
          enable: TvBoxNormalizers.asBool(
            ruleMap['enable'],
            path: '$path.enable',
            issueSink: issueSink,
          ),
          match: TvBoxNormalizers.asString(
            ruleMap['match'],
            path: '$path.match',
            issueSink: issueSink,
          ),
          replace: TvBoxNormalizers.asString(
            ruleMap['replace'],
            path: '$path.replace',
            issueSink: issueSink,
          ),
          priority: TvBoxNormalizers.asInt(
            ruleMap['priority'],
            path: '$path.priority',
            issueSink: issueSink,
          ),
        ),
      );
    }
    return result;
  }

  TvBoxPlayer? _parsePlayer(dynamic raw, TvBoxIssueSink issueSink) {
    final map = TvBoxNormalizers.asMap(
      raw,
      path: r'$.player',
      issueSink: issueSink,
    );
    if (map == null) return null;
    return TvBoxPlayer(
      raw: map,
      extras: _extrasFromMap(map, const {'ua', 'headers', 'timeout', 'retry'}),
      ua: TvBoxNormalizers.asString(
        map['ua'],
        path: r'$.player.ua',
        issueSink: issueSink,
      ),
      headers: TvBoxNormalizers.asMap(
        map['headers'],
        path: r'$.player.headers',
        issueSink: issueSink,
      ),
      timeout: TvBoxNormalizers.asInt(
        map['timeout'],
        path: r'$.player.timeout',
        issueSink: issueSink,
      ),
      retry: TvBoxNormalizers.asInt(
        map['retry'],
        path: r'$.player.retry',
        issueSink: issueSink,
      ),
    );
  }

  Map<String, dynamic> _extrasFromRoot(Map<String, dynamic> map) {
    return _extrasFromMap(
      map,
      const {
        'spider',
        'wallpaper',
        'logo',
        'sites',
        'parses',
        'lives',
        'flags',
        'ijk',
        'ads',
        'drives',
        'rules',
        'player',
        'cache',
        'proxy',
        'dns',
        'headers',
        'ua',
        'timeout',
        'recommend',
        'hotSearch',
        'ext',
      },
    );
  }

  Map<String, dynamic> _extrasFromMap(Map<String, dynamic> map, Set<String> knownKeys) {
    final extras = <String, dynamic>{};
    for (final entry in map.entries) {
      if (!knownKeys.contains(entry.key)) {
        extras[entry.key] = entry.value;
      }
    }
    return extras;
  }

  Map<String, dynamic> _mergeMapPreferLocal(
    Map<String, dynamic> base,
    Map<String, dynamic> local,
  ) {
    final merged = <String, dynamic>{...base};
    for (final entry in local.entries) {
      final existing = merged[entry.key];
      if (existing is Map && entry.value is Map) {
        merged[entry.key] = _mergeMapPreferLocal(
          Map<String, dynamic>.from(existing),
          Map<String, dynamic>.from(entry.value as Map),
        );
      } else {
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }
}

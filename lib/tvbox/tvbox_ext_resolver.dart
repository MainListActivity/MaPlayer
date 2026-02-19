import 'dart:convert';

import 'package:ma_palyer/tvbox/tvbox_parse_report.dart';
import 'package:ma_palyer/tvbox/tvbox_source_resolver.dart';

class TvBoxExtResolver {
  TvBoxExtResolver({
    required this.sourceResolver,
    this.maxDepth = 8,
    this.maxNodes = 200,
    Duration? requestTimeout,
  }) : requestTimeout = requestTimeout ?? const Duration(seconds: 8);

  final TvBoxSourceResolver sourceResolver;
  final int maxDepth;
  final int maxNodes;
  final Duration requestTimeout;

  final Set<String> _visited = <String>{};
  int _nodes = 0;

  void reset() {
    _visited.clear();
    _nodes = 0;
  }

  Future<Map<String, dynamic>?> resolveExtToMap({
    required dynamic extValue,
    required String path,
    required Uri? baseUri,
    required void Function(
      TvBoxIssueLevel level,
      String code,
      String issuePath,
      String message, {
      Object? rawValue,
    })
    issueSink,
    int depth = 0,
  }) async {
    if (extValue is! String || extValue.trim().isEmpty) {
      return null;
    }

    if (depth > maxDepth) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_DEPTH_LIMIT',
        path,
        'ext 递归深度超过上限 $maxDepth。',
        rawValue: extValue,
      );
      return null;
    }

    if (_nodes >= maxNodes) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_NODE_LIMIT',
        path,
        'ext 节点数量超过上限 $maxNodes。',
      );
      return null;
    }
    _nodes++;

    final uri = _resolveUri(extValue, baseUri);
    if (uri == null) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_URI_INVALID',
        path,
        'ext 不是合法 URI。',
        rawValue: extValue,
      );
      return null;
    }

    final key = _canonicalUri(uri);
    if (_visited.contains(key)) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_CYCLE',
        path,
        '检测到 ext 循环引用。',
        rawValue: uri.toString(),
      );
      return null;
    }

    _visited.add(key);

    try {
      final source = await sourceResolver.load(uri, timeout: requestTimeout);
      final decoded = jsonDecode(source);
      if (decoded is! Map) {
        issueSink(
          TvBoxIssueLevel.error,
          'TVB_EXT_NON_OBJECT',
          path,
          'ext 指向的 JSON 根节点不是 object。',
          rawValue: uri.toString(),
        );
        return null;
      }

      final localMap = Map<String, dynamic>.from(decoded);
      final nestedExt = localMap['ext'];
      if (nestedExt is String && nestedExt.trim().isNotEmpty) {
        final nestedMap = await resolveExtToMap(
          extValue: nestedExt,
          path: '$path.ext',
          baseUri: uri,
          issueSink: issueSink,
          depth: depth + 1,
        );
        if (nestedMap != null) {
          return _mergeMapPreferLocal(nestedMap, localMap);
        }
      }
      return localMap;
    } on FormatException catch (e) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_JSON_PARSE',
        path,
        'ext JSON 解析失败: ${e.message}',
        rawValue: uri.toString(),
      );
      return null;
    } on UnsupportedError catch (e) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_SCHEME_UNSUPPORTED',
        path,
        'ext scheme 不支持: $e',
        rawValue: uri.toString(),
      );
      return null;
    } catch (e) {
      issueSink(
        TvBoxIssueLevel.error,
        'TVB_EXT_LOAD_FAILED',
        path,
        'ext 拉取失败: $e',
        rawValue: uri.toString(),
      );
      return null;
    } finally {
      _visited.remove(key);
    }
  }

  Uri? _resolveUri(String raw, Uri? baseUri) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return null;
    if (parsed.hasScheme) return parsed;
    if (baseUri != null) return baseUri.resolveUri(parsed);
    return parsed;
  }

  String _canonicalUri(Uri uri) {
    return uri.normalizePath().toString();
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

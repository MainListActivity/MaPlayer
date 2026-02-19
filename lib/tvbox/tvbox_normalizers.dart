import 'package:ma_palyer/tvbox/tvbox_parse_report.dart';

typedef TvBoxIssueSink = void Function(
  TvBoxIssueLevel level,
  String code,
  String path,
  String message, {
  Object? rawValue,
});

class TvBoxNormalizers {
  static String? asString(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_STRING',
  }) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();
    issueSink(
      TvBoxIssueLevel.warning,
      code,
      path,
      '字段期望 string，已忽略。',
      rawValue: value,
    );
    return null;
  }

  static int? asInt(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_INT',
  }) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    issueSink(
      TvBoxIssueLevel.warning,
      code,
      path,
      '字段期望 int，已忽略。',
      rawValue: value,
    );
    return null;
  }

  static bool? asBool(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_BOOL',
  }) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    issueSink(
      TvBoxIssueLevel.warning,
      code,
      path,
      '字段期望 bool，已忽略。',
      rawValue: value,
    );
    return null;
  }

  static Map<String, dynamic>? asMap(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_MAP',
  }) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    issueSink(
      TvBoxIssueLevel.warning,
      code,
      path,
      '字段期望 object，已忽略。',
      rawValue: value,
    );
    return null;
  }

  static List<String> asStringList(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_STRING_LIST',
  }) {
    if (value == null) return const <String>[];
    if (value is! List) {
      issueSink(
        TvBoxIssueLevel.warning,
        code,
        path,
        '字段期望数组，已忽略。',
        rawValue: value,
      );
      return const <String>[];
    }

    final result = <String>[];
    for (var i = 0; i < value.length; i++) {
      final item = asString(
        value[i],
        path: '$path[$i]',
        issueSink: issueSink,
        code: code,
      );
      if (item != null && item.trim().isNotEmpty) {
        result.add(item);
      }
    }
    return result;
  }

  static List<Map<String, dynamic>> asMapList(
    dynamic value, {
    required String path,
    required TvBoxIssueSink issueSink,
    String code = 'TVB_TYPE_MAP_LIST',
  }) {
    if (value == null) return const <Map<String, dynamic>>[];
    if (value is! List) {
      issueSink(
        TvBoxIssueLevel.warning,
        code,
        path,
        '字段期望对象数组，已忽略。',
        rawValue: value,
      );
      return const <Map<String, dynamic>>[];
    }

    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < value.length; i++) {
      final item = asMap(
        value[i],
        path: '$path[$i]',
        issueSink: issueSink,
        code: code,
      );
      if (item != null) {
        result.add(item);
      }
    }
    return result;
  }
}

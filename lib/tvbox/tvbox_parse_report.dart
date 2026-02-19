import 'package:ma_palyer/tvbox/tvbox_models.dart';

enum TvBoxIssueLevel {
  fatal,
  error,
  warning,
}

class TvBoxIssue {
  const TvBoxIssue({
    required this.code,
    required this.path,
    required this.level,
    required this.message,
    this.rawValue,
  });

  final String code;
  final String path;
  final TvBoxIssueLevel level;
  final String message;
  final Object? rawValue;
}

class TvBoxParseReport {
  const TvBoxParseReport({
    required this.issues,
    this.config,
  });

  final TvBoxConfig? config;
  final List<TvBoxIssue> issues;

  bool get hasFatalError => issues.any((issue) => issue.level == TvBoxIssueLevel.fatal);
  int get errorCount => issues.where((issue) => issue.level == TvBoxIssueLevel.error).length;
  int get warningCount => issues.where((issue) => issue.level == TvBoxIssueLevel.warning).length;
}

import 'package:flutter/material.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';
import 'package:ma_palyer/tvbox/tvbox_parse_report.dart';
import 'package:ma_palyer/tvbox/tvbox_parser.dart';

void main() {
  runApp(const MaPlayerApp());
}

class MaPlayerApp extends StatelessWidget {
  const MaPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const baseColor = Color(0xFFF47B25);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ma Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: baseColor,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101622),
        useMaterial3: true,
      ),
      home: const TvBoxConfigPage(),
    );
  }
}

class TvBoxConfigPage extends StatefulWidget {
  const TvBoxConfigPage({super.key});

  @override
  State<TvBoxConfigPage> createState() => _TvBoxConfigPageState();
}

class _TvBoxConfigPageState extends State<TvBoxConfigPage> {
  final _sourceUrlController = TextEditingController();
  final _rawJsonController = TextEditingController();
  final _repository = TvBoxConfigRepository();
  final _parser = TvBoxParser();

  TvBoxParseReport? _report;
  String? _fetchErrorText;
  bool _isLoading = false;
  bool _isHydrating = true;

  @override
  void initState() {
    super.initState();
    _hydrateDraft();
  }

  @override
  void dispose() {
    _sourceUrlController.dispose();
    _rawJsonController.dispose();
    super.dispose();
  }

  Future<void> _hydrateDraft() async {
    final draft = await _repository.loadDraft();
    _sourceUrlController.text = draft.sourceUrl;
    _rawJsonController.text = draft.rawJson;

    if (_rawJsonController.text.trim().isNotEmpty) {
      await _parseWithCurrentInput(showSuccessSnackBar: false);
    }

    if (!mounted) return;
    setState(() {
      _isHydrating = false;
    });
  }

  Future<void> _saveDraft() async {
    await _repository.saveDraft(
      sourceUrl: _sourceUrlController.text.trim(),
      rawJson: _rawJsonController.text.trim(),
    );
  }

  Future<void> _importFromUrl() async {
    final url = _sourceUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _fetchErrorText = '请先输入 TVBox 订阅地址。';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _fetchErrorText = null;
    });

    try {
      final rawJson = await _repository.fetchFromUrl(url);
      _rawJsonController.text = rawJson;
      await _saveDraft();
      await _parseWithCurrentInput();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchErrorText = '导入失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _parseWithCurrentInput({bool showSuccessSnackBar = true}) async {
    final rawJson = _rawJsonController.text.trim();
    if (rawJson.isEmpty) {
      setState(() {
        _report = TvBoxParseReport(
          config: null,
          issues: const <TvBoxIssue>[
            TvBoxIssue(
              code: 'TVB_JSON_EMPTY',
              path: r'$',
              level: TvBoxIssueLevel.error,
              message: '请粘贴 TVBox JSON 配置。',
            ),
          ],
        );
      });
      return;
    }

    final baseUri = Uri.tryParse(_sourceUrlController.text.trim());
    final report = await _parser.parseString(rawJson, baseUri: baseUri);
    await _saveDraft();

    if (!mounted) return;
    setState(() {
      _report = report;
      _fetchErrorText = null;
    });

    if (showSuccessSnackBar) {
      final text = report.hasFatalError
          ? '解析失败（存在致命错误）'
          : report.errorCount > 0 || report.warningCount > 0
          ? '解析完成（存在问题项）'
          : 'TVBox 配置解析成功';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final config = report?.config;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(centerTitle: false, title: const Text('Ma Player')),
      body: _isHydrating
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFF192233),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF2E3B56)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Configuration',
                              style: textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '整合初始化配置与设计稿配置入口，管理数据源和云盘连接。',
                              style: textTheme.bodyMedium?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      _SectionCard(
                        title: 'Data Source',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _sourceUrlController,
                              decoration: const InputDecoration(
                                labelText: 'Subscription URL',
                                hintText: 'https://example.com/tvbox.json',
                                prefixIcon: Icon(Icons.link),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                FilledButton.icon(
                                  onPressed: _isLoading ? null : _importFromUrl,
                                  icon: const Icon(Icons.cloud_download),
                                  label: Text(
                                    _isLoading ? '导入中...' : '从 URL 导入',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _saveDraft,
                                  icon: const Icon(Icons.save_outlined),
                                  label: const Text('保存'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _rawJsonController,
                              maxLines: 14,
                              minLines: 10,
                              decoration: const InputDecoration(
                                alignLabelWithHint: true,
                                labelText: 'TVBox JSON',
                                hintText:
                                    '{"sites":[...],"parses":[...],"lives":[...]}',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _parseWithCurrentInput,
                              icon: const Icon(Icons.data_object),
                              label: const Text('解析配置'),
                            ),
                          ],
                        ),
                      ),
                      if (_fetchErrorText != null) ...[
                        const SizedBox(height: 12),
                        _SectionCard(
                          title: '导入错误',
                          child: Text(
                            _fetchErrorText!,
                            style: const TextStyle(color: Color(0xFFFF9A9A)),
                          ),
                        ),
                      ],
                      if (report != null) ...[
                        const SizedBox(height: 12),
                        _SectionCard(
                          title: '解析状态',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _SummaryChip(
                                label: '状态',
                                value: report.hasFatalError
                                    ? '失败'
                                    : report.errorCount > 0 ||
                                          report.warningCount > 0
                                    ? '部分成功'
                                    : '成功',
                              ),
                              _SummaryChip(
                                label: 'Error',
                                value: '${report.errorCount}',
                              ),
                              _SummaryChip(
                                label: 'Warning',
                                value: '${report.warningCount}',
                              ),
                              _SummaryChip(
                                label: 'Issue',
                                value: '${report.issues.length}',
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _SectionCard(
                        title: 'Cloud Drives',
                        child: _DriveSection(config: config),
                      ),
                      if (config != null) ...[
                        const SizedBox(height: 12),
                        _SectionCard(
                          title: '解析结果概览',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _SummaryChip(
                                label: '站点',
                                value: '${config.sites.length}',
                              ),
                              _SummaryChip(
                                label: '可搜索站点',
                                value: '${config.enabledSiteCount}',
                              ),
                              _SummaryChip(
                                label: '直播源',
                                value: '${config.lives.length}',
                              ),
                              _SummaryChip(
                                label: '解析线路',
                                value: '${config.parses.length}',
                              ),
                              _SummaryChip(
                                label: '云盘',
                                value: '${config.drives.length}',
                              ),
                              _SummaryChip(
                                label: '规则',
                                value: '${config.rules.length}',
                              ),
                              _SummaryChip(
                                label: 'Flags',
                                value: '${config.flags.length}',
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (report != null && report.issues.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _SectionCard(
                          title: '问题列表（最多显示 20 条）',
                          child: Column(
                            children: report.issues.take(20).map((issue) {
                              final color = switch (issue.level) {
                                TvBoxIssueLevel.fatal => const Color(
                                  0xFFFF6B6B,
                                ),
                                TvBoxIssueLevel.error => const Color(
                                  0xFFFF9F43,
                                ),
                                TvBoxIssueLevel.warning => const Color(
                                  0xFFFFD166,
                                ),
                              };
                              return Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF232F48),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: color.withValues(alpha: 0.65),
                                  ),
                                ),
                                child: Text(
                                  '[${issue.code}] ${issue.path} - ${issue.message}',
                                  style: TextStyle(color: color),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _DriveSection extends StatelessWidget {
  const _DriveSection({required this.config});

  final TvBoxConfig? config;

  @override
  Widget build(BuildContext context) {
    final drives = config?.drives ?? const <TvBoxDrive>[];
    if (drives.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF232F48),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('当前配置未解析到云盘信息。'),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: drives.map((drive) => _DriveCard(drive: drive)).toList(),
    );
  }
}

class _DriveCard extends StatelessWidget {
  const _DriveCard({required this.drive});

  final TvBoxDrive drive;

  @override
  Widget build(BuildContext context) {
    final name = drive.name ?? drive.provider ?? drive.key ?? 'Unknown Drive';
    final provider = drive.provider ?? '-';
    final hasApi = (drive.api?.trim().isNotEmpty ?? false);
    final hasExt = drive.ext != null;
    final isConnected = hasApi || hasExt;

    return Container(
      width: 320,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF232F48),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isConnected
                      ? const Color(0x33F47B25)
                      : const Color(0x1FFFFFFF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isConnected
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                  size: 18,
                  color: isConnected ? const Color(0xFFF47B25) : Colors.white70,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Provider: $provider',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 4),
          Text(
            '状态: ${isConnected ? 'Connected' : 'Not Connected'}',
            style: TextStyle(
              color: isConnected
                  ? const Color(0xFF93E3A2)
                  : const Color(0xFFFFD166),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF192233),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2E3B56)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF232F48),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$label: $value'),
    );
  }
}

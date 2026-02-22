import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/features/cloud/quark/quark_auth_service.dart';
import 'package:ma_palyer/features/cloud/quark/quark_login_webview_page.dart';
import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = TvBoxConfigRepository();
  final _urlController = TextEditingController();
  final _remoteJsUrlController = TextEditingController();
  final _homeUaController = TextEditingController();
  final _authService = QuarkAuthService();

  bool _isSaving = false;
  bool _isLoading = true;
  QuarkAuthState? _authState;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _remoteJsUrlController.dispose();
    _homeUaController.dispose();
    super.dispose();
  }

  Future<void> _hydrate() async {
    final url = await _repo.loadHomeSiteUrlOrDefault();
    final remoteJsUrl = await _repo.loadHomeBridgeRemoteJsUrlOrNull();
    final homeUa = await _repo.loadHomeWebViewUserAgentOrNull();
    final auth = await _authService.currentAuthState();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _remoteJsUrlController.text = remoteJsUrl ?? '';
      _homeUaController.text = homeUa ?? '';
      _authState = auth;
      _isLoading = false;
    });
  }

  Future<void> _saveHomeUrl() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) return;
    final remoteRaw = _remoteJsUrlController.text.trim();
    final homeUaRaw = _homeUaController.text.trim();
    setState(() {
      _isSaving = true;
    });
    try {
      await _repo.saveHomeSiteUrl(raw);
      await _repo.saveHomeBridgeRemoteJsUrl(
        remoteRaw.isEmpty ? null : remoteRaw,
      );
      await _repo.saveHomeWebViewUserAgent(
        homeUaRaw.isEmpty ? null : homeUaRaw,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('配置已保存，正在返回首页加载')));
      Navigator.pushReplacementNamed(context, AppRoutes.home);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _openQuarkLogin() async {
    final ok = await QuarkLoginWebviewPage.open(context, _authService);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('夸克登录态已更新')));
      await _hydrate();
    }
  }

  Future<void> _logoutQuark() async {
    await _authService.clearAuthState();
    if (!mounted) return;
    setState(() {
      _authState = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已退出夸克登录')));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
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
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Configuration',
                      key: Key('settings-page-title'),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '配置主页站点地址与夸克登录状态。',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Home Site URL',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Homepage URL',
                        hintText: 'https://www.wogg.net/',
                        prefixIcon: Icon(Icons.link),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _remoteJsUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Remote Bridge JS URL (optional)',
                        hintText: 'https://example.com/home-bridge.js',
                        prefixIcon: Icon(Icons.code),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _homeUaController,
                      decoration: const InputDecoration(
                        labelText: 'Home WebView UA (optional)',
                        hintText: 'Mozilla/5.0 ...',
                        prefixIcon: Icon(Icons.devices),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _saveHomeUrl,
                      icon: const Icon(Icons.save),
                      label: Text(_isSaving ? '保存中...' : '保存配置并加载首页'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Quark Account',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _authState == null ? '状态: 未登录' : '状态: 已登录',
                      style: TextStyle(
                        color: _authState == null
                            ? const Color(0xFFFFD166)
                            : const Color(0xFF93E3A2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _openQuarkLogin,
                          icon: const Icon(Icons.login),
                          label: const Text('打开夸克登录页'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _logoutQuark,
                          icon: const Icon(Icons.logout),
                          label: const Text('退出登录'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.all(14),
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
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

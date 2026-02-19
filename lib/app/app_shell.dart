import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.currentRoute,
    required this.child,
    this.repository,
  });

  final AppRoute currentRoute;
  final Widget child;
  final TvBoxConfigRepository? repository;

  TvBoxConfigRepository get _repository =>
      repository ?? TvBoxConfigRepository();

  Future<void> _onMenuTap(BuildContext context, AppRoute targetRoute) async {
    if (targetRoute == currentRoute) {
      return;
    }

    final hasConfig = await _repository.hasAnyDraftConfig();
    if (!hasConfig && targetRoute != AppRoute.settings) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先完成 TVBox 配置')));
      Navigator.pushReplacementNamed(context, AppRoutes.settings);
      return;
    }

    if (!context.mounted) return;
    Navigator.pushReplacementNamed(context, AppRoutes.pathFor(targetRoute));
  }

  void _onBackTap(BuildContext context) {
    if (currentRoute == AppRoute.home) {
      return;
    }
    Navigator.pushReplacementNamed(context, AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: currentRoute == AppRoute.home
            ? null
            : IconButton(
                key: const Key('app-back-button'),
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _onBackTap(context),
              ),
        title: const Text('Ma Player'),
        centerTitle: false,
        actions: AppRoutes.menuItems.map((item) {
          final selected = item.route == currentRoute;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TextButton.icon(
              key: Key('menu-${item.route.name}'),
              onPressed: () => _onMenuTap(context, item.route),
              icon: Icon(
                item.icon,
                size: 18,
                color: selected ? const Color(0xFFF47B25) : Colors.white70,
              ),
              label: Text(
                item.label,
                style: TextStyle(
                  color: selected ? const Color(0xFFF47B25) : Colors.white70,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        }).toList(),
      ),
      body: child,
    );
  }
}

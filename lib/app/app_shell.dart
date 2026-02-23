import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ma_palyer/app/app_route.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.currentRoute, required this.child});

  final AppRoute currentRoute;
  final Widget child;

  Future<void> _onMenuTap(BuildContext context, AppRoute targetRoute) async {
    if (targetRoute == currentRoute) {
      return;
    }

    if (!context.mounted) return;
    Navigator.pushReplacementNamed(context, AppRoutes.pathFor(targetRoute));
  }

  Widget _buildSidebar(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final sidebarWidth = screenWidth * 0.15 > 180.0
        ? screenWidth * 0.15
        : 180.0;

    return Container(
      width: sidebarWidth,
      color: const Color(0xFF192233),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 20),
              child: Row(
                children: [
                  SvgPicture.asset(
                    'logo/ma_player_logo.svg',
                    width: 32,
                    height: 32,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Ma Player',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ...AppRoutes.menuItems.map((item) {
              final selected = item.route == currentRoute;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextButton.icon(
                  key: Key('menu-${item.route.name}'),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    backgroundColor: selected
                        ? const Color(0xFFF47B25).withValues(alpha: 0.15)
                        : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _onMenuTap(context, item.route),
                  icon: Icon(
                    item.icon,
                    size: 22,
                    color: selected ? const Color(0xFFF47B25) : Colors.white70,
                  ),
                  label: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 15,
                      color: selected
                          ? const Color(0xFFF47B25)
                          : Colors.white70,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final selectedIndex = AppRoutes.menuItems
        .indexWhere((item) => item.route == currentRoute)
        .clamp(0, AppRoutes.menuItems.length - 1);

    return NavigationBar(
      backgroundColor: const Color(0xFF192233),
      indicatorColor: const Color(0xFFF47B25).withValues(alpha: 0.20),
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) =>
          _onMenuTap(context, AppRoutes.menuItems[index].route),
      destinations: AppRoutes.menuItems.map((item) {
        return NavigationDestination(
          icon: Icon(item.icon, color: Colors.white70),
          selectedIcon: Icon(item.icon, color: const Color(0xFFF47B25)),
          label: item.label,
        );
      }).toList(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _buildSidebar(context),
          Expanded(child: child),
        ],
      ),
    );
  }
}

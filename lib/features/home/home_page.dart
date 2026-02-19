import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return _SkeletonPage(
      title: 'Home',
      subtitle: '首页骨架已就绪，可直接进入 Playback Debug 验证主链路。',
      icon: Icons.home_outlined,
    );
  }
}

class _SkeletonPage extends StatelessWidget {
  const _SkeletonPage({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF192233),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2E3B56)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 32, color: const Color(0xFFF47B25)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('home-page-title'),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.pushNamed(context, AppRoutes.player);
                        },
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('进入 Playback Debug'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

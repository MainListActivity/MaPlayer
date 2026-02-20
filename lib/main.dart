import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_bootstrap_page.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/app/app_shell.dart';
import 'package:ma_palyer/features/home/home_page.dart';
import 'package:ma_palyer/features/history/history_page.dart';
import 'package:ma_palyer/features/movies/movies_page.dart';
import 'package:ma_palyer/features/player/player_page.dart';
import 'package:ma_palyer/features/settings/settings_page.dart';
import 'package:ma_palyer/features/tv_shows/tv_shows_page.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
      initialRoute: AppRoutes.bootstrap,
      onGenerateRoute: _onGenerateRoute,
    );
  }

  Route<dynamic> _onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.bootstrap:
        return MaterialPageRoute<void>(
          builder: (_) => const AppBootstrapPage(),
          settings: settings,
        );
      case AppRoutes.home:
        return _buildMenuRoute(
          settings: settings,
          currentRoute: AppRoute.home,
          child: const HomePage(),
        );
      case AppRoutes.movies:
        return _buildMenuRoute(
          settings: settings,
          currentRoute: AppRoute.movies,
          child: const MoviesPage(),
        );
      case AppRoutes.history:
        return _buildMenuRoute(
          settings: settings,
          currentRoute: AppRoute.history,
          child: const HistoryPage(),
        );
      case AppRoutes.tvShows:
        return _buildMenuRoute(
          settings: settings,
          currentRoute: AppRoute.tvShows,
          child: const TvShowsPage(),
        );
      case AppRoutes.settings:
        return _buildMenuRoute(
          settings: settings,
          currentRoute: AppRoute.settings,
          child: const SettingsPage(),
        );
      case AppRoutes.player:
        final args = settings.arguments;
        return PageRouteBuilder<void>(
          settings: settings,
          pageBuilder: (_, __, ___) =>
              PlayerPage(args: args is PlayerPageArgs ? args : null),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        );
      default:
        return MaterialPageRoute<void>(
          builder: (_) => const AppBootstrapPage(),
          settings: settings,
        );
    }
  }

  PageRouteBuilder<void> _buildMenuRoute({
    required RouteSettings settings,
    required AppRoute currentRoute,
    required Widget child,
  }) {
    return PageRouteBuilder<void>(
      settings: settings,
      pageBuilder: (_, __, ___) =>
          AppShell(currentRoute: currentRoute, child: child),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }
}

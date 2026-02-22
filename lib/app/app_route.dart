import 'package:flutter/material.dart';

final class AppRouteObserver extends RouteObserver<ModalRoute<void>> {
  AppRouteObserver._();
  static final AppRouteObserver instance = AppRouteObserver._();
}

enum AppRoute { home, movies, tvShows, settings, player, history, bootstrap }

class AppMenuItem {
  const AppMenuItem({
    required this.route,
    required this.path,
    required this.label,
    required this.icon,
  });

  final AppRoute route;
  final String path;
  final String label;
  final IconData icon;
}

class AppRoutes {
  static const bootstrap = '/bootstrap';
  static const home = '/home';
  static const movies = '/movies';
  static const tvShows = '/tv-shows';
  static const settings = '/settings';
  static const player = '/player';
  static const history = '/history';

  static const menuItems = <AppMenuItem>[
    AppMenuItem(
      route: AppRoute.home,
      path: home,
      label: 'Home',
      icon: Icons.home_outlined,
    ),
    AppMenuItem(
      route: AppRoute.history,
      path: history,
      label: 'History',
      icon: Icons.history_outlined,
    ),
    AppMenuItem(
      route: AppRoute.settings,
      path: settings,
      label: 'Settings',
      icon: Icons.settings_outlined,
    ),
  ];

  static AppRoute fromPath(String? path) {
    switch (path) {
      case home:
        return AppRoute.home;
      case movies:
        return AppRoute.movies;
      case tvShows:
        return AppRoute.tvShows;
      case settings:
        return AppRoute.settings;
      case player:
        return AppRoute.player;
      case history:
        return AppRoute.history;
      default:
        return AppRoute.bootstrap;
    }
  }

  static String pathFor(AppRoute route) {
    return switch (route) {
      AppRoute.bootstrap => bootstrap,
      AppRoute.home => home,
      AppRoute.movies => movies,
      AppRoute.tvShows => tvShows,
      AppRoute.settings => settings,
      AppRoute.player => player,
      AppRoute.history => history,
    };
  }
}

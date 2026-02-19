import 'package:flutter/material.dart';

enum AppRoute { home, movies, tvShows, settings, bootstrap }

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

  static const menuItems = <AppMenuItem>[
    AppMenuItem(
      route: AppRoute.home,
      path: home,
      label: 'Home',
      icon: Icons.home_outlined,
    ),
    AppMenuItem(
      route: AppRoute.movies,
      path: movies,
      label: 'Movies',
      icon: Icons.movie_outlined,
    ),
    AppMenuItem(
      route: AppRoute.tvShows,
      path: tvShows,
      label: 'TV Shows',
      icon: Icons.live_tv_outlined,
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
    };
  }
}

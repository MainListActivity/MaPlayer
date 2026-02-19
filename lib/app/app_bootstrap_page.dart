import 'package:flutter/material.dart';
import 'package:ma_palyer/app/app_route.dart';
import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';

class AppBootstrapPage extends StatefulWidget {
  const AppBootstrapPage({super.key, this.repository});

  final TvBoxConfigRepository? repository;

  @override
  State<AppBootstrapPage> createState() => _AppBootstrapPageState();
}

class _AppBootstrapPageState extends State<AppBootstrapPage> {
  TvBoxConfigRepository get _repository =>
      widget.repository ?? TvBoxConfigRepository();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final hasConfig = await _repository.hasAnyDraftConfig();
    if (!mounted) return;

    final nextRoute = hasConfig ? AppRoutes.home : AppRoutes.settings;
    Navigator.pushNamedAndRemoveUntil(context, nextRoute, (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

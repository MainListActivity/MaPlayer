import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const MaPlayerApp());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bootstrap_unconfigured_goes_to_settings', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);

    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);
    expect(find.byKey(const Key('menu-settings')), findsOneWidget);
  });

  testWidgets('bootstrap_configured_goes_to_home', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tvbox_raw_json': '{"sites":[]}',
    });

    await _pumpApp(tester);

    expect(find.byKey(const Key('home-page-title')), findsOneWidget);
  });

  testWidgets('menu_switch_route_when_configured', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tvbox_source_url': 'https://example.com/tvbox.json',
    });

    await _pumpApp(tester);
    expect(find.byKey(const Key('home-page-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-movies')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movies-page-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-tvShows')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tvshows-page-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);
  });

  testWidgets('menu_block_non_settings_when_unconfigured', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-home')));
    await tester.pumpAndSettle();

    expect(find.text('请先完成 TVBox 配置'), findsOneWidget);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);
  });

  testWidgets('settings_parse_flow_still_works', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);
    expect(find.byKey(const Key('settings-page-title')), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'TVBox JSON'),
      '{"sites":[]}',
    );
    await tester.ensureVisible(find.byKey(const Key('parse-config-button')));
    await tester.tap(find.byKey(const Key('parse-config-button')));
    await tester.pumpAndSettle();

    expect(find.text('解析状态'), findsOneWidget);
  });

  testWidgets('home_renders_sites_from_tvbox_config', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tvbox_raw_json':
          '{"sites":[{"key":"demo","name":"演示源","api":"https://example.com/api","searchable":1}]}',
    });

    await tester.pumpWidget(const MaPlayerApp());
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byKey(const Key('source-menu-demo')).evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const Key('home-page-title')), findsWidgets);
    expect(find.byKey(const Key('source-menu-demo')), findsWidgets);
    expect(find.text('演示源'), findsWidgets);
  });
}

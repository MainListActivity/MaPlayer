import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const MaPlayerApp());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bootstrap_goes_to_home', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);

    expect(find.byKey(const Key('home-page-title')), findsOneWidget);
    expect(find.byKey(const Key('menu-home')), findsOneWidget);
    expect(find.byKey(const Key('menu-settings')), findsOneWidget);
  });

  testWidgets('home_shows_settings_menu_button', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);
    expect(find.byKey(const Key('menu-settings')), findsOneWidget);
  });

  testWidgets('home_uses_webview_placeholder_in_test_env', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await _pumpApp(tester);

    expect(find.byKey(const Key('home-webview-placeholder')), findsOneWidget);
  });
}

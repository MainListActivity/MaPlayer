import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/home/home_page.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('renders placeholder when webview platform unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomePage())),
    );

    expect(find.byKey(const Key('home-webview-placeholder')), findsOneWidget);
  });
}

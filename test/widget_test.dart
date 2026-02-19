import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders TVBox config page', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaPlayerApp());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Ma Player TVBox 配置'), findsOneWidget);
    expect(find.text('兼容 TVBox 协议的配置入口'), findsOneWidget);
  });

  testWidgets('shows issue summary when draft contains invalid json', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tvbox_raw_json': '[1,2,3]',
    });

    await tester.pumpWidget(const MaPlayerApp());
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('解析状态'), findsOneWidget);
    expect(find.textContaining('TVB_JSON_ROOT_NOT_OBJECT'), findsOneWidget);
  });
}

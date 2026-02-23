import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/main.dart';
import 'package:ma_palyer/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const MaPlayerApp());
    await tester.pumpAndSettle();
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:surfeye_app/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SurfEyeApp());
    expect(find.byType(SurfEyeApp), findsOneWidget);
  });
}

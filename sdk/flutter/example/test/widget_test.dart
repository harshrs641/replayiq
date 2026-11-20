import 'package:flutter_test/flutter_test.dart';
import 'package:replayiq_flutter_example/main.dart';

void main() {
  testWidgets('checkout screen renders without the SDK initialized', (
    tester,
  ) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pumpAndSettle();
    expect(find.text('Pay now'), findsOneWidget);
    expect(find.text('Not recording'), findsOneWidget);
  });
}

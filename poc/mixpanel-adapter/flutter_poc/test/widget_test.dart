import 'package:flutter_test/flutter_test.dart';

import 'package:replayiq_mobile_poc/main.dart';

void main() {
  testWidgets('checkout screen renders and explains a missing RIQ_URL', (tester) async {
    await tester.pumpWidget(const PocApp());
    await tester.pump();

    expect(find.text('Checkout'), findsOneWidget);
    expect(find.text('Pay now'), findsOneWidget);
    expect(find.text('Load prices (fails)'), findsOneWidget);
    expect(find.textContaining('RIQ_URL not set'), findsOneWidget);

    // Stop the companion's flush timer (widget tests fail on pending timers).
    await companion.dispose();
  });
}

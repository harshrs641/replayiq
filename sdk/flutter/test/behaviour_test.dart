import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayiq_flutter/src/behaviour/errors_console.dart';
import 'package:replayiq_flutter/src/behaviour/navigation.dart';
import 'package:replayiq_flutter/src/behaviour/touch.dart';

typedef Recorded = List<(String, Map<String, Object?>)>;

void main() {
  group('RageTapDetector', () {
    test('3 taps within 700 ms and 48 pt is one rage burst', () {
      final d = RageTapDetector();
      expect(d.add(const Offset(100, 100), 0), isFalse);
      expect(d.add(const Offset(110, 105), 200), isFalse);
      expect(d.add(const Offset(105, 98), 400), isTrue);
      expect(d.add(const Offset(105, 98), 500), isFalse); // same burst
    });

    test('slow or spread-out taps are not rage', () {
      final d = RageTapDetector();
      expect(d.add(const Offset(0, 0), 0), isFalse);
      expect(d.add(const Offset(0, 0), 400), isFalse);
      expect(d.add(const Offset(0, 0), 1200), isFalse); // first fell out
      final e = RageTapDetector();
      e.add(const Offset(0, 0), 0);
      e.add(const Offset(200, 0), 100);
      expect(e.add(const Offset(0, 0), 200), isFalse);
    });
  });

  group('TouchRecorder', () {
    late List<Map<String, Object?>> touches;
    late Recorded app;
    late Recorded gestures;
    late TouchRecorder recorder;
    var t = Duration.zero;

    PointerEvent down(Offset p) =>
        PointerDownEvent(pointer: 1, position: p, timeStamp: t);
    PointerEvent move(Offset p) =>
        PointerMoveEvent(pointer: 1, position: p, timeStamp: t);
    PointerEvent up(Offset p) =>
        PointerUpEvent(pointer: 1, position: p, timeStamp: t);

    setUp(() {
      touches = [];
      app = [];
      gestures = [];
      t = Duration.zero;
      recorder = TouchRecorder(
        emit: touches.add,
        app: (s, f) => s == 'gesture' ? gestures.add((s, f)) : app.add((s, f)),
        isActive: () => true,
        selectorAt: (_) => 'button:"Pay now"',
      );
    });

    test('a tap is down + up, plus a click with the selector', () {
      recorder.handle(down(const Offset(196, 610)));
      t += const Duration(milliseconds: 80);
      recorder.handle(up(const Offset(196, 610)));
      expect(touches.map((e) => e['phase']), ['down', 'up']);
      expect(touches.first, containsPair('x', 196));
      expect(touches.first, containsPair('subtype', 'touch'));
      expect(app.single.$1, 'click');
      expect(app.single.$2['selector'], 'button:"Pay now"');
    });

    test('moves are sampled at most every 50 ms; a drag is not a click', () {
      recorder.handle(down(const Offset(10, 10)));
      for (var i = 1; i <= 10; i++) {
        t += const Duration(milliseconds: 16);
        recorder.handle(move(Offset(10, 10.0 + i * 20)));
      }
      recorder.handle(up(const Offset(10, 210)));
      final moves = touches.where((e) => e['phase'] == 'move').length;
      expect(moves, inInclusiveRange(2, 4));
      expect(app, isEmpty);
    });

    test('rapid taps add a rage_click', () {
      for (var i = 0; i < 3; i++) {
        recorder.handle(down(const Offset(50, 50)));
        t += const Duration(milliseconds: 40);
        recorder.handle(up(const Offset(50, 50)));
        t += const Duration(milliseconds: 100);
      }
      expect(app.map((e) => e.$1), ['click', 'click', 'click', 'rage_click']);
      expect(app.last.$2, {'selector': 'button:"Pay now"', 'x': 50, 'y': 50});
    });

    test('gestures: tap, double tap, long press, swipe, pan, pinch', () {
      List<String?> kinds() => [
        for (final g in gestures) g.$2['kind'] as String?,
      ];
      void tapAt(Offset p, Duration hold) {
        recorder.handle(down(p));
        t += hold;
        recorder.handle(up(p));
      }

      tapAt(const Offset(10, 10), const Duration(milliseconds: 60));
      t += const Duration(milliseconds: 100);
      tapAt(const Offset(12, 10), const Duration(milliseconds: 60));
      expect(kinds(), ['tap', 'tap', 'double_tap']);

      gestures.clear();
      t += const Duration(seconds: 2);
      tapAt(const Offset(10, 10), const Duration(milliseconds: 800));
      expect(kinds(), ['long_press']);

      gestures.clear();
      recorder.handle(down(const Offset(300, 100)));
      t += const Duration(milliseconds: 120);
      recorder.handle(up(const Offset(100, 100)));
      expect(kinds(), ['swipe']);
      expect(gestures.single.$2['dx'], -200);

      gestures.clear();
      recorder.handle(down(const Offset(100, 100)));
      t += const Duration(milliseconds: 900);
      recorder.handle(move(const Offset(100, 160)));
      recorder.handle(up(const Offset(100, 160)));
      expect(kinds(), ['pan']);

      gestures.clear();
      recorder.handle(down(const Offset(100, 100)));
      recorder.handle(
        PointerDownEvent(
          pointer: 2,
          position: const Offset(200, 100),
          timeStamp: t,
        ),
      );
      t += const Duration(milliseconds: 60);
      recorder.handle(
        PointerMoveEvent(
          pointer: 2,
          position: const Offset(300, 100),
          timeStamp: t,
        ),
      );
      recorder.handle(
        PointerUpEvent(
          pointer: 2,
          position: const Offset(300, 100),
          timeStamp: t,
        ),
      );
      recorder.handle(up(const Offset(100, 100)));
      expect(kinds(), ['pinch']);
      expect(gestures.single.$2['scale'], 2.0);
      expect(app.where((e) => e.$1 == 'click'), hasLength(2));
    });

    test('nothing is recorded while inactive', () {
      final r = TouchRecorder(
        emit: touches.add,
        app: (s, f) => app.add((s, f)),
        isActive: () => false,
        selectorAt: (_) => null,
      );
      r.handle(down(Offset.zero));
      r.handle(up(Offset.zero));
      expect(touches, isEmpty);
      expect(app, isEmpty);
    });
  });

  group('navigation', () {
    testWidgets('named routes become app:// navigations', (tester) async {
      final Recorded events = [];
      final observer = ReplayIQNavigatorObserver(
        (s, f) => events.add((s, f)),
        () => 'app://com.acme.shop',
      );
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [observer],
          routes: {
            '/': (_) => const Text('home'),
            '/order-summary': (_) => const Text('summary'),
          },
        ),
      );
      nav.currentState!.pushNamed('/order-summary');
      await tester.pumpAndSettle();
      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const Text('dialog'),
      );
      await tester.pumpAndSettle();
      nav.currentState!.pop(); // the dialog: not a screen change
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pumpAndSettle();

      expect(events.map((e) => e.$2['url']), [
        'app://com.acme.shop/',
        'app://com.acme.shop/order-summary',
        'app://com.acme.shop/',
      ]);
      expect(events.every((e) => e.$1 == 'navigate'), isTrue);
      expect(observer.currentPath, '');
    });
  });

  group('errors and console', () {
    test('errors carry the first app frame', () {
      final Recorded events = [];
      final c = ErrorConsoleRecorder((s, f) => events.add((s, f)));
      c.recordError(
        StateError('boom'),
        StackTrace.fromString(
          '#0      List.[] (dart:core-patch/growable_array.dart:264:36)\n'
          '#1      CheckoutScreen.build.<anonymous closure> (package:shop/main.dart:108:17)\n',
        ),
        context: 'gesture',
      );
      final e = events.single.$2;
      expect(events.single.$1, 'js_error');
      expect(e['message'], 'gesture: Bad state: boom');
      expect(e['filename'], 'package:shop/main.dart');
      expect(e['lineno'], 108);
      expect(e['colno'], 17);
    });

    test(
      'print output is recorded once; Flutter error reports are skipped',
      () {
        final Recorded events = [];
        final c = ErrorConsoleRecorder((s, f) => events.add((s, f)));
        c.runZoned(() {
          // ignore: avoid_print
          print('Checkout opened');
          // ignore: avoid_print
          print('══╡ EXCEPTION CAUGHT BY GESTURE ╞════');
          // ignore: avoid_print
          print('details...');
          // ignore: avoid_print
          print('═════════════');
          // ignore: avoid_print
          print('[replayiq] own log line');
        });
        expect(events.map((e) => e.$2['message']), ['Checkout opened']);
        expect(events.single.$2['level'], 'log');
      },
    );
  });
}

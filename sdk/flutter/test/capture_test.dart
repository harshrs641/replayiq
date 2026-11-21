import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayiq_flutter/replayiq_flutter.dart';
import 'package:replayiq_flutter/src/capture/mask_detector.dart';
import 'package:replayiq_flutter/src/capture/screen_capturer.dart';
import 'package:replayiq_flutter/src/capture/screen_recorder.dart';

CapturedFrame frame(
  List<int> bytes, {
  required DateTime at,
  Size size = const Size(393, 852),
}) => CapturedFrame(
  jpeg: Uint8List.fromList(bytes),
  logicalSize: size,
  capturedAt: at,
  maskCount: 0,
);

void main() {
  group('ScreenRecorder', () {
    late List<Map<String, Object?>> events;
    late List<CaptureOutcome> queue;
    late DateTime now;
    late ScreenRecorder recorder;

    Future<void> captureNext() async {
      recorder.request();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    setUp(() {
      events = [];
      queue = [];
      now = DateTime.utc(2026, 11, 19, 10);
      recorder = ScreenRecorder(
        capture: () async => queue.removeAt(0),
        emit: events.add,
        minInterval: Duration.zero,
        now: () => now,
        listenToFrames: false,
      );
    });
    tearDown(() => recorder.stop());

    test('first frame is a keyframe, unchanged frames are skipped', () async {
      queue.addAll([
        CaptureOk(frame([1, 2, 3], at: now)),
        CaptureOk(frame([1, 2, 3], at: now.add(const Duration(seconds: 1)))),
        CaptureOk(frame([9, 9], at: now.add(const Duration(seconds: 2)))),
      ]);
      recorder.start(); // captures the first
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await captureNext();
      await captureNext();

      expect(events.length, 2);
      expect(events[0], containsPair('keyframe', true));
      expect(events[0], containsPair('subtype', 'screen'));
      expect(events[0], containsPair('width', 393));
      expect(events[0]['image'], startsWith('data:image/jpeg;base64,'));
      expect(events[1], containsPair('keyframe', false));
    });

    test(
      'a size change or 30 s since the last keyframe makes a keyframe',
      () async {
        final t0 = now;
        queue.addAll([
          CaptureOk(frame([1], at: t0)),
          CaptureOk(
            frame(
              [2],
              at: t0.add(const Duration(seconds: 1)),
              size: const Size(852, 393),
            ),
          ),
          CaptureOk(
            frame(
              [3],
              at: t0.add(const Duration(seconds: 2)),
              size: const Size(852, 393),
            ),
          ),
          // Unchanged, but a keyframe is due: still sent.
          CaptureOk(
            frame(
              [3],
              at: t0.add(const Duration(seconds: 33)),
              size: const Size(852, 393),
            ),
          ),
        ]);
        recorder.start();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        for (var i = 0; i < 3; i++) {
          await captureNext();
        }
        expect(events.map((e) => e['keyframe']), [true, true, false, true]);
      },
    );

    test('a new session forces a keyframe', () async {
      queue.addAll([
        CaptureOk(frame([1], at: now)),
        CaptureOk(frame([2], at: now.add(const Duration(seconds: 1)))),
      ]);
      recorder.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      recorder.markKeyframeNeeded();
      await captureNext();
      expect(events.map((e) => e['keyframe']), [true, true]);
    });

    test('nothing is captured while stopped', () async {
      queue.add(CaptureOk(frame([1], at: now)));
      recorder.request();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(events, isEmpty);
      expect(queue.length, 1);
    });
  });

  group('MaskDetector', () {
    Future<List<MaskRegion>> regionsFor(
      WidgetTester tester,
      Widget body, {
      bool maskAllText = false,
      bool maskAllImages = false,
    }) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
      final view = tester.binding.renderViews.first;
      return MaskDetector(
        maskAllText: maskAllText,
        maskAllImages: maskAllImages,
      ).detect(view.child!, tester.binding.rootElement!).regions;
    }

    testWidgets('text fields are always masked, plain text is not', (
      tester,
    ) async {
      final regions = await regionsFor(
        tester,
        const Column(
          children: [
            Text('Hello'),
            TextField(decoration: InputDecoration(labelText: 'Name')),
            ReplayIQUnmask(child: TextField(obscureText: true)),
          ],
        ),
      );
      expect(regions.length, 2);
      expect(regions.every((r) => r.source == MaskSource.security), isTrue);
      final editable = tester.getRect(find.byType(EditableText).first);
      expect(regions.first.bounds.overlaps(editable), isTrue);
    });

    testWidgets('ReplayIQMask covers its whole child', (tester) async {
      final regions = await regionsFor(
        tester,
        const Center(
          child: ReplayIQMask(
            child: SizedBox(width: 120, height: 40, child: Text('4242')),
          ),
        ),
      );
      final box = tester.getRect(find.byType(SizedBox).last);
      expect(regions.first.source, MaskSource.manual);
      expect(regions.first.bounds, box);
    });

    testWidgets('maskAllText masks text except inside ReplayIQUnmask', (
      tester,
    ) async {
      final regions = await regionsFor(
        tester,
        const Column(
          children: [
            Text('secret'),
            ReplayIQUnmask(child: Text('public')),
          ],
        ),
        maskAllText: true,
      );
      expect(regions.length, 1);
      expect(regions.single.bounds, tester.getRect(find.text('secret')));
    });

    testWidgets('background routes are not walked', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: TextField()),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('two')),
        ),
      );
      await tester.pumpAndSettle();
      final view = tester.binding.renderViews.first;
      final result = MaskDetector().detect(
        view.child!,
        tester.binding.rootElement!,
      );
      expect(result.regions, isEmpty);
      expect(result.shouldSkipCapture, isFalse);
    });
  });

  testWidgets('ScreenCapturer paints masks over the pixels before encoding', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Color(0xFFFF0000),
          child: Align(
            alignment: Alignment.topLeft,
            child: ReplayIQMask(child: SizedBox(width: 50, height: 50)),
          ),
        ),
      ),
    );
    Uint8List? rgba;
    int? w, h;
    final capturer = ScreenCapturer(
      detector: MaskDetector(),
      encode: (pixels, width, height, quality) async {
        rgba = Uint8List.fromList(pixels);
        w = width;
        h = height;
        return Uint8List.fromList([0xff, 0xd8]);
      },
    );
    final outcome = await tester.runAsync(capturer.capture);
    expect(outcome, isA<CaptureOk>());
    final f = (outcome! as CaptureOk).frame;
    expect(f.logicalSize, const Size(200, 100));
    expect(f.maskCount, greaterThanOrEqualTo(1));
    expect((w, h), (200, 100));
    List<int> pixel(int x, int y) {
      final i = (y * w! + x) * 4;
      return rgba!.sublist(i, i + 3);
    }

    expect(pixel(10, 10), isNot([255, 0, 0])); // masked
    expect(pixel(150, 80), [255, 0, 0]); // visible
  });
}

// A scripted user for measuring the recorder: the same taps, typing,
// navigation and scrolling every run, through real pointer events.
//
//   flutter run --dart-define=RIQ_AUTOPILOT=60 --dart-define=RIQ_MODE=nativeDom
//
// After the given number of seconds it prints one `RIQ_STATS {...}` line.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:replayiq_flutter/replayiq_flutter.dart';

final payKey = GlobalKey();
final summaryKey = GlobalKey();
final pricesKey = GlobalKey();
final nameKey = GlobalKey();
final navigatorKey = GlobalKey<NavigatorState>();
final nameController = TextEditingController();
final cardController = TextEditingController();

int _pointer = 1000;

Offset _centre(GlobalKey key) {
  final box = key.currentContext!.findRenderObject()! as RenderBox;
  return box.localToGlobal(box.size.center(Offset.zero));
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _tap(Offset p) async {
  final id = _pointer++;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: id, position: p),
  );
  await _wait(60);
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: id, position: p),
  );
}

Future<void> _drag(Offset from, Offset to, {int steps = 20}) async {
  final id = _pointer++;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: id, position: from),
  );
  for (var i = 1; i <= steps; i++) {
    await _wait(16);
    GestureBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: id,
        position: Offset.lerp(from, to, i / steps)!,
        delta: (to - from) / steps.toDouble(),
      ),
    );
  }
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: id, position: to),
  );
}

Future<void> _type(TextEditingController c, String text) async {
  for (final ch in text.split('')) {
    c.text += ch;
    await _wait(120);
  }
}

/// Runs the script until [seconds] have passed, then prints the stats.
Future<void> runAutopilot(int seconds) async {
  await _wait(1500);
  final end = DateTime.now().add(Duration(seconds: seconds));
  var round = 0;
  while (DateTime.now().isBefore(end)) {
    round++;
    await _tap(_centre(nameKey));
    await _wait(400);
    nameController.clear();
    await _type(nameController, 'Jane Doe');
    cardController.clear();
    await _type(cardController, '42424242');
    FocusManager.instance.primaryFocus?.unfocus();
    await _wait(500);
    for (var i = 0; i < 4; i++) {
      await _tap(_centre(payKey));
      await _wait(80);
    }
    await _wait(800);
    await _tap(_centre(summaryKey));
    await _wait(1200);
    final size = WidgetsBinding.instance.renderViews.first.size;
    final x = size.width / 2;
    await _drag(Offset(x, size.height * .8), Offset(x, size.height * .3));
    await _wait(1500);
    await _drag(Offset(x, size.height * .3), Offset(x, size.height * .8));
    await _wait(800);
    navigatorKey.currentState!.pop();
    await _wait(1200);
    await _tap(_centre(pricesKey));
    await _wait(2000);
    if (!DateTime.now().isBefore(end)) break;
  }
  await ReplayIQ.flush();
  // ignore: invalid_use_of_visible_for_testing_member
  final stats = ReplayIQ.debugStats() ?? {};
  // ignore: avoid_print
  print('RIQ_STATS ${jsonEncode({...stats, 'rounds': round})}');
}

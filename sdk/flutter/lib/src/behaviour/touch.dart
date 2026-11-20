// Touch capture: `touch` events for the replay, `click` / `rage_click` for
// the Behaviour tab. Primary-pointer tracking and move sampling follow
// mixpanel_flutter_session_replay 2.1.0 (InteractionDetector), Copyright 2022
// Mixpanel, Inc., Apache-2.0; see LICENSE and NOTICE. Changed: listens on the
// global pointer route (no wrapper widget) and emits Recording API v1 events.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';

import 'navigation.dart' show AppEventSink;

/// Taps for rage detection: 3+ within 700 ms and 48 pt of each other.
class RageTapDetector {
  RageTapDetector({
    this.window = const Duration(milliseconds: 700),
    this.radius = 48,
    this.threshold = 3,
  });

  final Duration window;
  final double radius;
  final int threshold;

  final List<({Offset at, int t})> _taps = [];
  bool _reported = false;

  /// Adds a tap; true when it completes a rage burst (once per burst).
  bool add(Offset at, int timestampMs) {
    final windowMs = window.inMilliseconds;
    _taps.removeWhere((p) => timestampMs - p.t > windowMs);
    if (_taps.isNotEmpty && (_taps.last.at - at).distance > radius) {
      _taps.clear();
    }
    if (_taps.isEmpty) _reported = false;
    _taps.add((at: at, t: timestampMs));
    final close = _taps.every((p) => (p.at - at).distance <= radius);
    if (!close) {
      _taps
        ..clear()
        ..add((at: at, t: timestampMs));
      _reported = false;
      return false;
    }
    if (_taps.length >= threshold && !_reported) {
      _reported = true;
      return true;
    }
    return false;
  }
}

class TouchRecorder {
  TouchRecorder({
    required this.emit,
    required this.app,
    required this.isActive,
    required this.selectorAt,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Receives `touch` events (type 5).
  final void Function(Map<String, Object?> event) emit;

  /// Receives `click` / `rage_click`.
  final AppEventSink app;
  final bool Function() isActive;
  final String? Function(Offset position) selectorAt;
  final DateTime Function() _now;

  static const _moveInterval = Duration(milliseconds: 50);
  static const _tapSlop = 18.0;
  static const _tapMaxDuration = Duration(milliseconds: 700);

  final RageTapDetector _rage = RageTapDetector();
  int? _pointer;
  Offset _downAt = Offset.zero;
  Duration _downStamp = Duration.zero;
  Duration _lastMoveStamp = Duration.zero;
  bool _moved = false;
  bool _installed = false;

  // Pinch: the second finger and the starting distance.
  int? _second;
  Offset _primaryAt = Offset.zero;
  Offset _secondAt = Offset.zero;
  double? _pinchStart;

  // Double tap: the previous tap.
  ({Offset at, Duration t})? _lastTap;
  static const _longPress = Duration(milliseconds: 500);
  static const _doubleTapGap = Duration(milliseconds: 300);

  void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(handle);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(handle);
  }

  void handle(PointerEvent event) {
    try {
      _handle(event);
    } catch (_) {
      // Never break the app's input.
    }
  }

  void _handle(PointerEvent event) {
    if (event is PointerDownEvent &&
        _pointer != null &&
        _second == null &&
        event.pointer != _pointer) {
      _second = event.pointer;
      _secondAt = event.position;
      _pinchStart = (_primaryAt - _secondAt).distance;
      return;
    }
    if (event.pointer == _second) {
      if (event is PointerMoveEvent) _secondAt = event.position;
      if (event is PointerUpEvent || event is PointerCancelEvent) _endPinch();
      return;
    }
    if (event is PointerDownEvent) {
      if (_pointer != null || !isActive()) return;
      if (event.kind != PointerDeviceKind.touch &&
          event.kind != PointerDeviceKind.mouse &&
          event.kind != PointerDeviceKind.stylus) {
        return;
      }
      _pointer = event.pointer;
      _downAt = event.position;
      _primaryAt = event.position;
      _downStamp = event.timeStamp;
      _lastMoveStamp = event.timeStamp;
      _moved = false;
      _touch(event.position, 'down');
    } else if (event is PointerMoveEvent) {
      if (event.pointer != _pointer) return;
      _primaryAt = event.position;
      if ((event.position - _downAt).distance > _tapSlop) _moved = true;
      if (event.timeStamp - _lastMoveStamp < _moveInterval) return;
      _lastMoveStamp = event.timeStamp;
      _touch(event.position, 'move');
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event.pointer != _pointer) return;
      _pointer = null;
      _touch(event.position, 'up');
      if (_second != null || _pinchStart != null) {
        _endPinch();
        return;
      }
      if (event is! PointerUpEvent || !isActive()) return;
      if ((event.position - _downAt).distance > _tapSlop) _moved = true;
      final held = event.timeStamp - _downStamp;
      if (!_moved && held <= _tapMaxDuration && held < _longPress) {
        _tap(_downAt, event.timeStamp);
      } else if (!_moved) {
        _gesture('long_press', _downAt);
      } else {
        final d = event.position - _downAt;
        final secs = math.max(held.inMicroseconds / 1e6, 0.001);
        final fast = d.distance / secs > 800 && held.inMilliseconds < 400;
        _gesture(fast ? 'swipe' : 'pan', _downAt, delta: d);
      }
    }
  }

  void _endPinch() {
    final start = _pinchStart;
    _second = null;
    _pinchStart = null;
    if (start == null || start <= 0 || !isActive()) return;
    final scale = (_primaryAt - _secondAt).distance / start;
    final mid = (_primaryAt + _secondAt) / 2;
    _gesture('pinch', mid, scale: scale);
    _pointer = null; // the gesture is over; ignore the other finger's up
  }

  void _gesture(String kind, Offset at, {Offset? delta, double? scale}) {
    app('gesture', {
      'kind': kind,
      'selector': selectorAt(at) ?? 'view',
      'x': _round(at.dx),
      'y': _round(at.dy),
      if (delta != null) 'dx': _round(delta.dx),
      if (delta != null) 'dy': _round(delta.dy),
      if (scale != null) 'scale': (scale * 100).round() / 100,
    });
  }

  void _touch(Offset p, String phase) {
    emit({
      'type': 5,
      'subtype': 'touch',
      'timestamp': _now().millisecondsSinceEpoch,
      'x': _round(p.dx),
      'y': _round(p.dy),
      'phase': phase,
    });
  }

  void _tap(Offset p, Duration t) {
    final selector = selectorAt(p) ?? 'view';
    app('click', {'selector': selector});
    final g = {'selector': selector, 'x': _round(p.dx), 'y': _round(p.dy)};
    app('gesture', {'kind': 'tap', ...g});
    final last = _lastTap;
    if (last != null &&
        t - last.t <= _doubleTapGap &&
        (last.at - p).distance <= 40) {
      app('gesture', {'kind': 'double_tap', ...g});
      _lastTap = null;
    } else {
      _lastTap = (at: p, t: t);
    }
    if (_rage.add(p, _now().millisecondsSinceEpoch)) {
      app('rage_click', {
        'selector': selector,
        'x': _round(p.dx),
        'y': _round(p.dy),
      });
    }
  }

  static num _round(double v) => (v * 10).round() / 10;
}

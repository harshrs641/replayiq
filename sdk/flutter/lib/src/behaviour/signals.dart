// Mobile signals (Recording API v1.1 §2) that Flutter can supply without
// new dependencies: lifecycle, app_start, screen_load, jank, keyboard,
// orientation and memory.
import 'dart:io' show ProcessInfo;
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'navigation.dart' show AppEventSink;

/// Frame counts, for jank events and measurement.
class FrameStats {
  int frames = 0;
  int dropped = 0;
  int frozen = 0;
  int worstMicros = 0;

  Map<String, Object?> toJson() => {
    'frames': frames,
    'dropped': dropped,
    'frozen': frozen,
    'worst_ms': (worstMicros / 1000).round(),
  };
}

class SignalsRecorder with WidgetsBindingObserver {
  SignalsRecorder(
    this._sink, {
    required this.screen,
    this.window = const Duration(seconds: 5),
    this.droppedOver = const Duration(microseconds: 16700),
    this.frozenOver = const Duration(milliseconds: 700),
  });

  final AppEventSink _sink;

  /// The current screen (route path), for jank events.
  final String? Function() screen;
  final Duration window;
  final Duration droppedOver;
  final Duration frozenOver;

  /// Totals since install (for measurement).
  final FrameStats totals = FrameStats();
  FrameStats _window = FrameStats();
  DateTime _windowStart = DateTime.now();
  bool _installed = false;
  double? _keyboard;
  String? _orientation;
  bool _cold = true;

  void install() {
    if (_installed) return;
    _installed = true;
    final b = WidgetsBinding.instance;
    b.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    _readMetrics(emit: false);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }

  // ── Frames: jank ──

  @visibleForTesting
  void onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      addFrame(t.totalSpan);
    }
  }

  @visibleForTesting
  void addFrame(Duration span, {DateTime? at}) {
    final us = span.inMicroseconds;
    for (final s in [totals, _window]) {
      s.frames++;
      if (span > frozenOver) {
        s.frozen++;
      } else if (span > droppedOver) {
        s.dropped++;
      }
      s.worstMicros = math.max(s.worstMicros, us);
    }
    final now = at ?? DateTime.now();
    final elapsed = now.difference(_windowStart);
    if (elapsed >= window) {
      final w = _window;
      if (w.dropped > 0 || w.frozen > 0) {
        _sink('jank', {
          'screen': ?screen(),
          'dropped': w.dropped,
          'frozen': w.frozen,
          'worst': (w.worstMicros / 1000).round(),
          'window': elapsed.inMilliseconds,
        });
      }
      _window = FrameStats();
      _windowStart = now;
    }
  }

  // ── Keyboard and orientation ──

  @override
  void didChangeMetrics() => _readMetrics(emit: true);

  void _readMetrics({required bool emit}) {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final v = views.first;
    final dpr = v.devicePixelRatio;
    final keyboard = (v.viewInsets.bottom / dpr).roundToDouble();
    final size = v.physicalSize;
    final orientation = size.width > size.height ? 'landscape' : 'portrait';
    if (emit && _keyboard != null && (keyboard > 0) != (_keyboard! > 0)) {
      _sink('keyboard', {'visible': keyboard > 0, 'height': keyboard});
    }
    if (emit && _orientation != null && orientation != _orientation) {
      _sink('orientation', {'value': orientation});
    }
    // Keyboard height animates: remember the settled value only.
    _keyboard = keyboard;
    _orientation = orientation;
  }

  // ── Memory ──

  @override
  void didHaveMemoryPressure() {
    int? used;
    try {
      used = ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {}
    _sink('memory', {'level': 'warning', 'used': ?used});
  }

  // ── Lifecycle and start-up ──

  /// `lifecycle` for a foreground/background/terminate transition.
  void lifecycle(String state) {
    _sink('lifecycle', {
      'state': state,
      'cold': state == 'foreground' && _cold,
    });
    if (state == 'foreground') _cold = false;
  }

  /// `app_start`: [startedAt] (process start, or resume for warm) until
  /// the next frame is on screen.
  Future<void> appStart(String kind, DateTime startedAt) async {
    try {
      if (kind == 'cold') {
        await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      } else {
        await SchedulerBinding.instance.endOfFrame;
      }
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      if (ms >= 0 && ms < 120000) {
        _sink('app_start', {'kind': kind, 'duration': ms});
      }
    } catch (_) {}
  }

  /// `screen_load`: a route was pushed; measured to the first frame of it.
  void routePushed(String screen) {
    final start = DateTime.now();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _sink('screen_load', {
        'screen': screen,
        'duration': DateTime.now().difference(start).inMilliseconds,
      });
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

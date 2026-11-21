import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../util/log.dart';
import 'assets.dart';
import 'differ.dart';
import 'node.dart';
import 'walker.dart';

/// Timing samples, for measuring the recorder's cost.
class DomStats {
  final List<int> walkMicros = [];
  final List<int> diffMicros = [];
  int snapshots = 0;
  int mutations = 0;
  int walks = 0;
  int nodes = 0;

  Map<String, Object?> toJson() => {
    'walks': walks,
    'snapshots': snapshots,
    'mutations': mutations,
    'last_nodes': nodes,
    'walk_us_p50': percentile(walkMicros, 50),
    'walk_us_p95': percentile(walkMicros, 95),
    'diff_us_p50': percentile(diffMicros, 50),
    'diff_us_p95': percentile(diffMicros, 95),
  };
}

int percentile(List<int> xs, int p) {
  if (xs.isEmpty) return 0;
  final s = List.of(xs)..sort();
  return s[math.min(s.length - 1, (s.length * p / 100).floor())];
}

/// Native-DOM recording (Recording API v1.1 §1): walks the render tree
/// after frames, at most every [minInterval], and emits `ui_snapshot` /
/// `ui_mutation` events.
class DomRecorder {
  DomRecorder({
    required this.walker,
    required this.assets,
    required this.emit,
    this.onWalk,
    this.minInterval = const Duration(milliseconds: 33),
    this.keyframeInterval = const Duration(seconds: 30),
    bool listenToFrames = true,
  }) : _listenToFrames = listenToFrames;

  final UiWalker walker;
  final AssetManager assets;
  final void Function(Map<String, Object?> event) emit;

  /// Called after each walk (mode decisions, islands).
  final void Function(WalkResult result, Size screen)? onWalk;
  final Duration minInterval;
  final Duration keyframeInterval;
  final bool _listenToFrames;
  final DomStats stats = DomStats();

  static bool _frameHook = false;
  static DomRecorder? _active;

  bool _running = false;
  bool _snapshotNeeded = true;
  Timer? _timer;
  DateTime? _lastWalk;
  DateTime? _lastSnapshot;
  Map<int, FlatNode>? _prev;
  Size? _prevSize;
  int _fontsSent = 0;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    _active = this;
    _snapshotNeeded = true;
    if (_listenToFrames && !_frameHook) {
      _frameHook = true;
      SchedulerBinding.instance.addPersistentFrameCallback(
        (_) => _active?.request(),
      );
    }
    request();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _prev = null;
  }

  /// The next walk sends a full `ui_snapshot` (route change, resume, mode
  /// switch).
  void markSnapshotNeeded() => _snapshotNeeded = true;

  /// Asks for a walk once the rate limit allows (trailing, coalesced).
  void request() {
    if (!_running || (_timer?.isActive ?? false)) return;
    final last = _lastWalk;
    final since = last == null ? minInterval : DateTime.now().difference(last);
    final wait = since >= minInterval ? Duration.zero : minInterval - since;
    // A timer, never inside the frame callback: the frame isn't laid out
    // and painted yet there.
    _timer = Timer(wait, _run);
  }

  void _run() {
    if (!_running) return;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.idle) {
      // Mid-frame (e.g. a microtask during build): try after it.
      scheduler.addPostFrameCallback((_) => request());
      return;
    }
    _lastWalk = DateTime.now();
    try {
      walkNow();
    } catch (e, st) {
      log('native DOM walk failed: $e\n$st');
    }
  }

  /// One walk + emit, synchronously (exposed for tests).
  void walkNow({DateTime? at}) {
    final views = WidgetsBinding.instance.renderViews;
    if (views.isEmpty) return;
    final view = views.first;
    final root = view.child;
    if (root == null || !root.hasSize) return;
    final now = at ?? DateTime.now();

    final sw = Stopwatch()..start();
    final result = walker.walk(root);
    stats.walkMicros.add(sw.elapsedMicroseconds);
    stats.walks++;
    stats.nodes = result.nodeCount;

    final size = root.size;
    onWalk?.call(result, size);
    if (!_running) return; // onWalk may switch to screenshots

    final fonts = assets.fontsFor(result.families);
    final snapshot =
        _snapshotNeeded ||
        _prev == null ||
        _prevSize != size ||
        fonts.length != _fontsSent ||
        (_lastSnapshot != null &&
            now.difference(_lastSnapshot!) >= keyframeInterval);

    sw
      ..reset()
      ..start();
    final flat = flatten(result.root);
    if (snapshot) {
      stats.diffMicros.add(sw.elapsedMicroseconds);
      _snapshotNeeded = false;
      _lastSnapshot = now;
      _prevSize = size;
      _fontsSent = fonts.length;
      _prev = flat;
      stats.snapshots++;
      emit({
        'type': 5,
        'subtype': 'ui_snapshot',
        'timestamp': now.millisecondsSinceEpoch,
        'width': size.width.round(),
        'height': size.height.round(),
        'density': view.flutterView.devicePixelRatio,
        'bg': _background(result.root),
        if (fonts.isNotEmpty) 'fonts': fonts,
        'root': result.root.toJson(),
      });
    } else {
      final d = diffTrees(_prev!, flat);
      stats.diffMicros.add(sw.elapsedMicroseconds);
      _prev = flat;
      if (!d.isEmpty) {
        stats.mutations++;
        emit({
          'type': 5,
          'subtype': 'ui_mutation',
          'timestamp': now.millisecondsSinceEpoch,
          if (d.adds.isNotEmpty) 'adds': d.adds,
          if (d.removes.isNotEmpty) 'removes': d.removes,
          if (d.updates.isNotEmpty) 'updates': d.updates,
        });
      }
    }
    if (result.islands.isNotEmpty) {
      unawaited(assets.captureIslands(result.islands));
    }
  }

  /// The first full-screen background found, else white.
  static String _background(UiNode root) {
    String? found;
    final w = root.f[2], h = root.f[3];
    root.visit((n, _) {
      if (found != null) return;
      final bg = n.s?['bg'];
      if (bg is String && n.f.length == 4 && n.f[2] >= w && n.f[3] >= h) {
        found = bg;
      }
    });
    return found ?? '#FFFFFFFF';
  }
}

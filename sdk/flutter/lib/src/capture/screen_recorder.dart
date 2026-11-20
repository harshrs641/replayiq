// Change-driven, rate-limited screenshot recording.
//
// The rate limiting and "one follow-up after a capture that overlapped a
// frame" logic is derived from mixpanel_flutter_session_replay 2.1.0
// (CaptureScheduler, FrameMonitor), Copyright 2022 Mixpanel, Inc.,
// Apache-2.0; see LICENSE and NOTICE. Keyframes, duplicate-frame dropping and
// the Recording API v1 event shape are ReplayIQ's.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/scheduler.dart';

import '../util/log.dart';
import 'screen_capturer.dart';

/// Largest data URL sent; the API takes events up to 2 MB.
const int maxImageChars = 1900 * 1024;

/// Abstracts [ScreenCapturer.capture] for tests.
typedef CaptureFn = Future<CaptureOutcome> Function();

class ScreenRecorder {
  ScreenRecorder({
    required this.capture,
    required this.emit,
    this.minInterval = const Duration(milliseconds: 500),
    this.keyframeInterval = const Duration(seconds: 30),
    DateTime Function()? now,
    bool listenToFrames = true,
  }) : _now = now ?? DateTime.now,
       _listenToFrames = listenToFrames;

  final CaptureFn capture;

  /// Receives `screen` events.
  final void Function(Map<String, Object?> event) emit;

  /// At most one frame per [minInterval] (spec: at most 2 fps).
  final Duration minInterval;

  /// A keyframe at least this often, even on a static screen.
  final Duration keyframeInterval;

  final DateTime Function() _now;
  final bool _listenToFrames;

  static bool _frameCallbackAdded = false;
  static ScreenRecorder? _active;

  bool _running = false;
  bool _inProgress = false;
  bool _pending = false;
  Timer? _timer;
  Timer? _keyframeTimer;
  DateTime? _lastCaptureAt;
  DateTime? _lastKeyframeAt;
  Size? _lastSize;
  int? _lastHash;
  bool _nextIsKeyframe = true;
  int _retries = 0;

  bool get isRunning => _running;

  /// Starts recording. The first frame is a keyframe.
  void start() {
    if (_running) return;
    _running = true;
    _active = this;
    if (_listenToFrames && !_frameCallbackAdded) {
      // Persistent callbacks cannot be removed; one static hook serves every
      // recorder the app ever creates.
      _frameCallbackAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback(
        (_) => _active?._onFrame(),
      );
    }
    _keyframeTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkKeyframeDue(),
    );
    request();
  }

  /// Stops capturing (app backgrounded, recording stopped).
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _keyframeTimer?.cancel();
    _keyframeTimer = null;
    _pending = false;
  }

  /// The next frame is sent as a keyframe (new session, app resumed).
  void markKeyframeNeeded() => _nextIsKeyframe = true;

  void _onFrame() {
    if (_running) request();
  }

  void _checkKeyframeDue() {
    final last = _lastKeyframeAt;
    if (_running &&
        last != null &&
        _now().difference(last) >= keyframeInterval) {
      request();
    }
  }

  /// Asks for a capture as soon as the rate limit allows.
  void request() {
    if (!_running) return;
    if (_inProgress) {
      _pending = true;
      return;
    }
    if (_timer?.isActive ?? false) return;
    final last = _lastCaptureAt;
    final elapsed = last == null ? minInterval : _now().difference(last);
    final wait = elapsed >= minInterval ? Duration.zero : minInterval - elapsed;
    // Always via a timer: never capture inside a frame callback, where the
    // frame being built is not painted yet.
    _timer = Timer(wait, _run);
  }

  Future<void> _run() async {
    if (!_running || _inProgress) return;
    _inProgress = true;
    _pending = false;
    try {
      final outcome = await capture();
      if (!_running) return;
      switch (outcome) {
        case CaptureOk(:final frame):
          _retries = 0;
          _handle(frame);
        case CaptureRetry(:final reason):
          // A transition ends with frames of its own; a few retries cover the
          // last one, after which the next UI change triggers a capture.
          if (_retries++ < 6) _pending = true;
          log('capture deferred: $reason');
        case CaptureFailed(:final reason):
          log('capture failed: $reason');
      }
    } catch (e) {
      log('capture error: $e');
    } finally {
      _inProgress = false;
      _lastCaptureAt = _now();
      if (_pending && _running) {
        _pending = false;
        request();
      }
    }
  }

  void _handle(CapturedFrame frame) {
    final now = frame.capturedAt;
    final size = frame.logicalSize;
    final keyframe =
        _nextIsKeyframe ||
        _lastSize != size ||
        _lastKeyframeAt == null ||
        now.difference(_lastKeyframeAt!) >= keyframeInterval;
    final hash = fnv1a(frame.jpeg);
    if (!keyframe && hash == _lastHash) return; // unchanged screen
    final image = 'data:image/jpeg;base64,${base64Encode(frame.jpeg)}';
    if (image.length > maxImageChars) {
      log('frame dropped: ${image.length} chars is over the event limit');
      return;
    }
    _lastHash = hash;
    _lastSize = size;
    if (keyframe) {
      _lastKeyframeAt = now;
      _nextIsKeyframe = false;
    }
    emit({
      'type': 5,
      'subtype': 'screen',
      'timestamp': now.millisecondsSinceEpoch,
      'width': size.width.round(),
      'height': size.height.round(),
      'image': image,
      'keyframe': keyframe,
    });
  }
}

/// 32-bit FNV-1a, to spot identical consecutive frames.
int fnv1a(Uint8List bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../transport/outbox.dart';
import '../transport/uploader.dart';
import '../util/ids.dart';
import '../util/log.dart';
import 'state_store.dart';

/// Host app and device, for the create-session request.
class DeviceInfo {
  const DeviceInfo({
    this.bundleId,
    this.os = 'unknown',
    this.osVersion,
    this.device,
    this.appVersion,
  });

  final String? bundleId;
  final String os;
  final String? osVersion;
  final String? device;
  final String? appVersion;

  static DeviceInfo fromMap(Map<String, String> m) => DeviceInfo(
    bundleId: m['bundle_id'],
    os: m['os'] ?? 'unknown',
    osVersion: m['os_version'],
    device: m['device'],
    appVersion: m['app_version'],
  );

  /// `app://<bundle id>`
  String get appUrlBase => 'app://${bundleId ?? 'flutter'}';
}

/// Sessions, batching and consent: everything between "an event happened"
/// and the outbox. Has no Flutter UI dependencies, so it is unit-tested
/// directly.
class Recorder {
  Recorder({
    required this.outbox,
    required this.uploader,
    required this.store,
    required this.device,
    required this.sdk,
    this.sampleRate = 1.0,
    this.flushInterval = const Duration(seconds: 5),
    this.backgroundTimeout = const Duration(minutes: 30),
    this.maxBatchEvents = 50,
    this.maxBatchBytes = 3 << 20,
    this.screenSize,
    this.currentRoute,
    this.metadataExtras,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random();

  final Outbox outbox;
  final Uploader uploader;
  final StateStore store;
  final DeviceInfo device;

  /// `replayiq-flutter/<version>`
  final String sdk;

  /// Share of sessions recorded, 0-1, decided per session.
  final double sampleRate;
  final Duration flushInterval;
  final Duration backgroundTimeout;
  final int maxBatchEvents;

  /// Flush early once buffered events reach roughly this size, so a body
  /// stays under the API's 5 MB.
  final int maxBatchBytes;

  /// Logical screen size, read when the session is created.
  final ({int width, int height})? Function()? screenSize;

  /// The route showing, for the session's `url`.
  final String? Function()? currentRoute;

  /// More `metadata` keys (locale, text scale, density), read at create.
  final Map<String, Object?> Function()? metadataExtras;

  final DateTime Function() _now;
  final Random _random;

  final List<Map<String, Object?>> _events = [];
  final List<Map<String, Object?>> _custom = [];
  int _bufferedBytes = 0;
  Timer? _flushTimer;
  Timer? _backgroundTimer;
  bool _started = false;
  bool _stopped = false;
  bool _unauthorized = false;
  bool _foreground = true;
  Future<void> _flushing = Future.value();

  /// True while events are captured: started, sampled, consented, foreground.
  final ValueNotifier<bool> capturing = ValueNotifier(false);

  /// Fires with the new session id whenever a session starts.
  final ValueNotifier<String?> sessionId = ValueNotifier(null);

  SessionState? get session => store.session;

  /// Whether events for the current session are kept (sampled in, consented,
  /// not stopped). Unlike [capturing], stays true in the background.
  bool get isRecording =>
      _started &&
      !_stopped &&
      !_unauthorized &&
      !store.optedOut &&
      (store.session?.sampled ?? false);

  // ── Lifecycle ──

  /// Resumes the session a previous launch left (if it was active less than
  /// [backgroundTimeout] ago) or starts a new one, then sends anything left
  /// queued.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _stopped = false;
    final now = _now();
    final s = store.session;
    if (s != null) {
      final idleSince = s.backgroundedAt ?? s.lastActive;
      if (now.difference(idleSince) >= backgroundTimeout) {
        await _queueEnd(s, idleSince);
        store.session = null;
      } else {
        s.backgroundedAt = null;
        sessionId.value = s.id;
      }
    }
    if (!store.optedOut && store.session == null) _newSession(now);
    await store.save();
    _flushTimer = Timer.periodic(flushInterval, (_) => flush());
    _update();
    unawaited(uploader.drain());
  }

  void _newSession(DateTime now) {
    final s = SessionState(
      id: uuidV4(),
      startedAt: now,
      lastActive: now,
      sampled: sampleRate >= 1 || _random.nextDouble() < sampleRate,
    );
    store.session = s;
    _events.clear();
    _custom.clear();
    _bufferedBytes = 0;
    log('session ${s.id} (${s.sampled ? 'recording' : 'not sampled'})');
    sessionId.value = s.id;
  }

  void onBackground() {
    if (!_foreground) return;
    _foreground = false;
    _update();
    final s = store.session;
    if (s == null) return;
    s.backgroundedAt = _now();
    s.lastActive = s.backgroundedAt!;
    unawaited(flush());
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(backgroundTimeout, () {
      // Fires only if the OS kept the app running; otherwise onForeground
      // (or the next launch) sees the elapsed time.
      unawaited(endSession(at: s.backgroundedAt));
    });
  }

  Future<void> onForeground() async {
    if (_foreground) return;
    _foreground = true;
    _backgroundTimer?.cancel();
    final now = _now();
    final s = store.session;
    if (s != null && s.backgroundedAt != null) {
      if (now.difference(s.backgroundedAt!) >= backgroundTimeout) {
        await endSession(at: s.backgroundedAt);
      } else {
        s.backgroundedAt = null;
      }
    }
    if (_started && !_stopped && !store.optedOut && store.session == null) {
      _newSession(now);
      await store.save();
    }
    _update();
  }

  /// Ends the current session: sends what is buffered, then the end call
  /// (which starts the AI analysis). A new session starts with the next
  /// foreground, [optIn] or [restart].
  Future<void> endSession({DateTime? at}) async {
    final s = store.session;
    if (s == null) return;
    await flush();
    await _queueEnd(s, at ?? _now());
    store.session = null;
    sessionId.value = null;
    await store.save();
    _update();
    unawaited(uploader.drain());
  }

  Future<void> _queueEnd(SessionState s, DateTime at) async {
    if (!s.created) return; // nothing was sent for it
    await outbox.add(RequestKind.endSession, '/api/v1/sessions/${s.id}/end', {
      'ended_at': isoUtc(at),
      'duration_ms': max(0, at.difference(s.startedAt).inMilliseconds),
    });
  }

  /// Ends the session and stops recording until [restart].
  Future<void> stop() async {
    await endSession();
    _stopped = true;
    _update();
  }

  /// Starts a new session after [stop].
  Future<void> restart() async {
    if (!_started) return start();
    _stopped = false;
    if (!store.optedOut && store.session == null) {
      _newSession(_now());
      await store.save();
    }
    _update();
  }

  /// The ingest key was rejected: record nothing more this app run.
  void onUnauthorized() {
    _unauthorized = true;
    _events.clear();
    _custom.clear();
    _update();
  }

  Future<void> optOut() async {
    store.optedOut = true;
    store.session = null;
    sessionId.value = null;
    _events.clear();
    _custom.clear();
    _bufferedBytes = 0;
    await outbox.clear();
    await store.save();
    _update();
  }

  Future<void> optIn() async {
    if (!store.optedOut) return;
    store.optedOut = false;
    if (_started && !_stopped && store.session == null) _newSession(_now());
    await store.save();
    _update();
  }

  /// Sets the user for this and later sessions. Sent with the session's
  /// create request, which goes out with its first batch; a later identify
  /// re-sends it.
  void identify(String userId, Map<String, Object?>? traits) {
    store.userId = userId;
    if (traits != null) {
      store.traits = {
        ...store.traits,
        for (final e in traits.entries)
          if (e.value != null) e.key: '${e.value}',
      };
    }
    final s = store.session;
    if (s != null && s.created) s.created = false; // re-send with the user
    unawaited(store.save());
  }

  void _update() {
    capturing.value = isRecording && _foreground;
  }

  // ── Events ──

  /// Buffers an event (`type`, `timestamp`, ...). Dropped unless recording.
  void record(Map<String, Object?> event) {
    if (!isRecording) return;
    event['timestamp'] ??= _now().millisecondsSinceEpoch;
    _events.add(event);
    final image = event['image'];
    _bufferedBytes += image is String ? image.length + 200 : 300;
    if (_events.length >= maxBatchEvents || _bufferedBytes >= maxBatchBytes) {
      unawaited(flush());
    }
  }

  /// A Custom app event (`subtype` plus fields), as the API describes.
  void recordApp(String subtype, Map<String, Object?> fields) {
    record({
      'type': 5,
      'subtype': subtype,
      'timestamp': _now().millisecondsSinceEpoch,
      for (final e in fields.entries)
        if (e.value != null) e.key: e.value,
    });
  }

  /// The app's own named event (`custom_events`).
  void track(String name, Map<String, Object?>? properties) {
    if (!isRecording) return;
    _custom.add({
      'name': name,
      'properties': properties ?? const {},
      'timestamp': _now().millisecondsSinceEpoch,
    });
  }

  int get bufferedEvents => _events.length + _custom.length;

  /// Moves buffered events into a persisted batch and sends the queue.
  Future<void> flush() {
    _flushing = _flushing.then((_) => _flush()).catchError((Object e) {
      log('flush failed: $e');
    });
    return _flushing;
  }

  Future<void> _flush() async {
    final s = store.session;
    if (s == null || !s.sampled || _unauthorized) {
      _events.clear();
      _custom.clear();
      _bufferedBytes = 0;
      return;
    }
    if (_events.isEmpty && _custom.isEmpty) {
      if (!outbox.isEmpty) await uploader.drain();
      return;
    }
    final events = List.of(
      _events,
    )..sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    final custom = List.of(_custom);
    _events.clear();
    _custom.clear();
    _bufferedBytes = 0;

    if (!s.created) {
      await outbox.add(
        RequestKind.createSession,
        '/api/v1/sessions',
        _createBody(s),
      );
      s.created = true;
    }
    final seq = s.seq++;
    s.lastActive = _now();
    await outbox.add(RequestKind.events, '/api/v1/events', {
      'session_id': s.id,
      'batch_id': '${s.id}-${seq.toString().padLeft(6, '0')}',
      'platform': 'flutter',
      'sdk': sdk,
      'device_masked': true,
      'flushed_at': isoUtc(_now()),
      'events': events,
      if (custom.isNotEmpty) 'custom_events': custom,
    });
    await store.save();
    unawaited(uploader.drain());
  }

  Map<String, Object?> _createBody(SessionState s) {
    final size = screenSize?.call();
    final route = currentRoute?.call();
    final ua = StringBuffer(sdk)
      ..write(' (${device.os}')
      ..write(device.osVersion == null ? '' : ' ${device.osVersion}')
      ..write(device.device == null ? '' : '; ${device.device}')
      ..write(')');
    return {
      'session_id': s.id,
      'user_id': ?store.userId,
      'url': '${device.appUrlBase}/${route ?? ''}',
      'user_agent': ua.toString(),
      'screen_width': ?size?.width,
      'screen_height': ?size?.height,
      'sdk_version': sdk,
      'started_at': isoUtc(s.startedAt),
      'metadata': {
        ...store.traits,
        'platform': 'flutter',
        'os': device.os,
        'os_version': ?device.osVersion,
        'app_version': ?device.appVersion,
        'device': ?device.device,
        ...?metadataExtras?.call(),
      },
    };
  }

  /// Queues an asset (`POST /api/v1/assets`) before later batches.
  Future<void> addAsset(String hash, Uint8List bytes, String type) async {
    if (!isRecording) return;
    await outbox.addAsset(hash, bytes, type);
    unawaited(uploader.drain());
  }

  void dispose() {
    _flushTimer?.cancel();
    _backgroundTimer?.cancel();
  }
}

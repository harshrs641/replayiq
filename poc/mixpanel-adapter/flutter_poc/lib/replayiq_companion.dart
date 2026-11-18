// ReplayIQ companion for the Mixpanel session replay SDK.
//
// The Mixpanel SDK records the screen (screenshots + touches) but not what
// the app does: screen changes, HTTP calls, errors, logs. This records those
// as ReplayIQ events, in the same shapes the web SDK uses, and sends them to
// the adapter's /riq/events route tagged with the SDK's replay id, so they
// land in the same ReplayIQ session as the screenshots. They then show in
// the dashboard's Behaviour / Console / Network tabs and the AI analysis.
//
//   final companion = ReplayIQCompanion(
//     adapterUrl: riqUrl, token: riqProject, replayId: () => replay?.replayId);
//   companion.installErrorHandlers();
//   MaterialApp(navigatorObservers: [companion.navigatorObserver], ...);
//   final client = companion.httpClient(); // use for API calls
//
// Text (log lines, URLs, stack traces) leaves the device unmasked; ReplayIQ
// redacts PII patterns in these fields on ingest.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

class ReplayIQCompanion {
  ReplayIQCompanion({
    required String adapterUrl,
    required this.token,
    required this.replayId,
    this.distinctId,
    http.Client? transport,
    this.flushInterval = const Duration(seconds: 5),
    this.maxBuffered = 1000,
    int Function()? now,
  })  : _endpoint = Uri.parse('${adapterUrl.replaceAll(RegExp(r'/+$'), '')}/riq/events'),
        _transport = transport ?? http.Client(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (flushInterval > Duration.zero) {
      _timer = Timer.periodic(flushInterval, (_) => flush());
    }
  }

  /// Sent as the Basic-auth user, like the Mixpanel SDK's token.
  final String token;

  /// The Mixpanel SDK's current replay id (`replay.replayId`). Read when an
  /// event happens, so events follow the SDK across replay sessions.
  final String? Function() replayId;
  final String? distinctId;
  final Duration flushInterval;

  /// Oldest events are dropped beyond this (e.g. adapter unreachable).
  final int maxBuffered;

  final Uri _endpoint;
  final http.Client _transport;
  final int Function() _now;
  final List<_Pending> _buffer = [];
  Timer? _timer;
  bool _flushing = false;
  bool _disposed = false;

  /// Number of events waiting to be sent (for tests and diagnostics).
  int get pending => _buffer.length;

  // ── Recording ──

  /// Records an event in the web SDK's shape (`subtype` plus its fields).
  void record(String subtype, Map<String, Object?> fields) {
    if (_disposed) return;
    final event = <String, Object?>{'subtype': subtype, 'timestamp': _now()};
    fields.forEach((k, v) {
      if (v != null) event[k] = v;
    });
    _buffer.add(_Pending(replayId(), event));
    if (_buffer.length > maxBuffered) _buffer.removeRange(0, _buffer.length - maxBuffered);
  }

  /// A log line, shown in the Console tab. Levels: log, warn, error.
  void log(String message, {String level = 'log', StackTrace? stack}) {
    record('console', {'level': level, 'message': message, 'stack': stack?.toString()});
  }

  /// An error, shown in the Console tab and used by the AI analysis.
  void recordError(Object error, StackTrace? stack, {String? context}) {
    final frame = _firstFrame(stack);
    record('js_error', {
      'message': context == null ? '$error' : '$context: $error',
      'stack': stack?.toString(),
      'filename': frame?.file,
      'lineno': frame?.line,
      'colno': frame?.column,
    });
  }

  // ── Hooks ──

  /// Add to `MaterialApp.navigatorObservers`. Screen changes become
  /// `app://flutter/<route name>` navigations; give routes a
  /// `RouteSettings(name: ...)` for readable names.
  late final NavigatorObserver navigatorObserver = _NavigationRecorder(this);

  /// An HTTP client that records every request's method, URL, status and
  /// duration (status 0 plus the error when no response arrives).
  http.Client httpClient([http.Client? inner]) => _RecordingClient(inner ?? http.Client(), this);

  /// Records Flutter framework errors and uncaught async errors, then hands
  /// them to whatever handlers were installed before.
  void installErrorHandlers() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      recordError(details.exception, details.stack, context: details.library);
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      recordError(error, stack, context: 'Uncaught');
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Runs [body] with `print`/`debugPrint` output recorded as console logs
  /// (the session replay SDK's own log lines are skipped).
  R runCapturingPrints<R>(R Function() body) {
    return runZoned(body, zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (_keepPrint(line)) log(line);
        parent.print(zone, line);
      },
    ));
  }

  bool _inErrorReport = false;

  // Skips the session replay SDK's own log lines, and the multi-line report
  // Flutter prints for each error ("══╡ EXCEPTION CAUGHT BY ... ╞══" up to a
  // closing "════" rule): installErrorHandlers already records that error,
  // with its stack, as one event.
  bool _keepPrint(String line) {
    if (line.startsWith('══╡')) {
      _inErrorReport = true;
      return false;
    }
    if (_inErrorReport) {
      if (RegExp(r'^═+$').hasMatch(line.trim())) _inErrorReport = false;
      return false;
    }
    return !line.contains('mixpanel.session_replay');
  }

  // ── Sending ──

  /// Sends buffered events, one request per replay id. Events recorded
  /// before the SDK had a replay id go with the current one. On failure they
  /// stay buffered and are retried next time.
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      final current = replayId();
      final batch = List<_Pending>.of(_buffer);
      final groups = <String, List<Map<String, Object?>>>{};
      final sent = <_Pending>{};
      for (final p in batch) {
        final id = p.replayId ?? current;
        if (id == null) continue; // recording hasn't started yet; keep
        groups.putIfAbsent(id, () => []).add(p.event);
        sent.add(p);
      }
      for (final entry in groups.entries) {
        final res = await _transport.post(
          _endpoint,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Basic ${base64Encode(utf8.encode('$token:'))}',
          },
          body: jsonEncode({
            'replay_id': entry.key,
            if (distinctId != null) 'distinct_id': distinctId,
            'os': defaultTargetPlatform.name,
            'events': entry.value,
          }),
        );
        if (res.statusCode >= 300) {
          throw http.ClientException('adapter returned HTTP ${res.statusCode}', _endpoint);
        }
        _buffer.removeWhere((p) => sent.contains(p) && (p.replayId ?? current) == entry.key);
      }
    } catch (e) {
      // Keep the events; the next flush retries. Never surface this to the app.
      // Root zone: inside runCapturingPrints this line would be captured as
      // a console event and grow the buffer it failed to send.
      if (kDebugMode) Zone.root.print('[replayiq companion] flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Sends what is left and stops the timer.
  Future<void> dispose() async {
    _timer?.cancel();
    await flush();
    _disposed = true;
  }
}

class _Pending {
  _Pending(this.replayId, this.event);
  final String? replayId;
  final Map<String, Object?> event;
}

class _Frame {
  _Frame(this.file, this.line, this.column);
  final String file;
  final int? line;
  final int? column;
}

// First frame of a Dart stack trace that points into the app rather than
// the SDK: "#0  main.<fn> (package:app/main.dart:42:7)".
final _frameRe = RegExp(r'\((\S+?):(\d+)(?::(\d+))?\)');

_Frame? _firstFrame(StackTrace? stack) {
  if (stack == null) return null;
  for (final line in stack.toString().split('\n')) {
    final m = _frameRe.firstMatch(line);
    if (m == null) continue;
    final file = m.group(1)!;
    if (file.startsWith('dart:') || file.startsWith('package:flutter/')) continue;
    return _Frame(file, int.tryParse(m.group(2)!), int.tryParse(m.group(3) ?? ''));
  }
  return null;
}

class _NavigationRecorder extends NavigatorObserver {
  _NavigationRecorder(this.companion);
  final ReplayIQCompanion companion;
  String? _current;

  void _record(Route<dynamic>? route) {
    if (route == null || route is PopupRoute) return; // dialogs, menus
    final name = route.settings.name;
    final path = (name == null || name.isEmpty || name == '/') ? '' : name.replaceFirst(RegExp(r'^/'), '');
    final url = 'app://flutter/$path';
    // A rebuilt Navigator re-pushes the screen already showing.
    if (url == _current) return;
    _current = url;
    companion.record('navigate', {'url': url, 'message': name ?? route.runtimeType.toString()});
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _record(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _record(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _record(newRoute);
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner, this._companion);
  final http.Client _inner;
  final ReplayIQCompanion _companion;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final watch = Stopwatch()..start();
    try {
      final res = await _inner.send(request);
      _companion.record('network', {
        'method': request.method,
        'url': request.url.toString(),
        'status': res.statusCode,
        'duration': watch.elapsedMilliseconds,
      });
      return res;
    } catch (e) {
      _companion.record('network', {
        'method': request.method,
        'url': request.url.toString(),
        'status': 0,
        'error': e.toString(),
        'duration': watch.elapsedMilliseconds,
      });
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

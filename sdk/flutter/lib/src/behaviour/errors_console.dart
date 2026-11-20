// Error and log capture. Ported from ReplayIQ's Flutter companion
// (poc/mixpanel-adapter/flutter_poc/lib/replayiq_companion.dart).
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'navigation.dart' show AppEventSink;

class ErrorConsoleRecorder {
  ErrorConsoleRecorder(this._sink);

  final AppEventSink _sink;
  bool _errorsInstalled = false;
  bool _debugPrintInstalled = false;
  bool _inErrorReport = false;
  final List<String> _fromDebugPrint = [];

  /// A log line for the Console tab. Levels: log, warn, error.
  void log(String message, {String level = 'log', StackTrace? stack}) {
    _sink('console', {
      'level': level,
      'message': message,
      if (stack != null) 'stack': stack.toString(),
    });
  }

  /// An error for the Console tab and the AI analysis.
  void recordError(Object error, StackTrace? stack, {String? context}) {
    final frame = firstAppFrame(stack);
    _sink('js_error', {
      'message': context == null ? '$error' : '$context: $error',
      if (stack != null) 'stack': stack.toString(),
      if (frame != null) 'filename': frame.file,
      if (frame?.line != null) 'lineno': frame!.line,
      if (frame?.column != null) 'colno': frame!.column,
    });
  }

  /// Records Flutter framework errors and uncaught async errors, then hands
  /// them to whatever handlers were installed before.
  void installErrorHandlers() {
    if (_errorsInstalled) return;
    _errorsInstalled = true;
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _guard(
        () => recordError(
          details.exception,
          details.stack,
          context: details.library,
        ),
      );
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _guard(() => recordError(error, stack, context: 'Uncaught'));
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Records `debugPrint` output. (`print` needs [runZoned].)
  void installDebugPrint() {
    if (_debugPrintInstalled) return;
    _debugPrintInstalled = true;
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        _guard(() {
          for (final line in message.split('\n')) {
            _line(line);
            // debugPrint ends in print; don't record that line twice.
            _fromDebugPrint.add(line);
            if (_fromDebugPrint.length > 500) _fromDebugPrint.removeAt(0);
          }
        });
      }
      previous(message, wrapWidth: wrapWidth);
    };
  }

  /// Runs [body] with `print` output recorded as console logs.
  R runZoned<R>(R Function() body) {
    return Zone.current
        .fork(
          specification: ZoneSpecification(
            print: (self, parent, zone, line) {
              _guard(() {
                if (!_fromDebugPrint.remove(line)) _line(line);
              });
              parent.print(zone, line);
            },
          ),
        )
        .run(body);
  }

  void _line(String line) {
    if (keepLine(line)) log(line);
  }

  /// Skips the multi-line report Flutter prints for each error
  /// ("══╡ EXCEPTION CAUGHT BY ... ╞══" up to a closing "════" rule): the
  /// error handlers already record that error, with its stack, as one event.
  @visibleForTesting
  bool keepLine(String line) {
    if (line.startsWith('══╡')) {
      _inErrorReport = true;
      return false;
    }
    if (_inErrorReport) {
      if (RegExp(r'^═+$').hasMatch(line.trim())) _inErrorReport = false;
      return false;
    }
    return !line.startsWith('[replayiq]');
  }

  void _guard(void Function() fn) {
    try {
      fn();
    } catch (_) {
      // Never let recording break the app's own error handling.
    }
  }
}

class StackFrameRef {
  StackFrameRef(this.file, this.line, this.column);
  final String file;
  final int? line;
  final int? column;
}

final _frameRe = RegExp(r'\((\S+?):(\d+)(?::(\d+))?\)');

/// The first frame of a Dart stack trace in app code (not dart: or Flutter):
/// `#0  main.<fn> (package:app/main.dart:42:7)`.
StackFrameRef? firstAppFrame(StackTrace? stack) {
  if (stack == null) return null;
  for (final line in stack.toString().split('\n')) {
    final m = _frameRe.firstMatch(line);
    if (m == null) continue;
    final file = m.group(1)!;
    if (file.startsWith('dart:') || file.startsWith('package:flutter/')) {
      continue;
    }
    return StackFrameRef(
      file,
      int.tryParse(m.group(2)!),
      int.tryParse(m.group(3) ?? ''),
    );
  }
  return null;
}

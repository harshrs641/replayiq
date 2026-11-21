import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether the SDK's own log lines are printed (debug builds only).
bool logEnabled = false;

/// The SDK's log lines are printed through the root zone, so they never
/// reach ReplayIQ's own print capture, and only in debug builds.
void log(String message) {
  if (!kDebugMode || !logEnabled) return;
  Zone.root.print('[replayiq] $message');
}

import 'dart:convert';
import 'dart:io';

import '../util/log.dart';

/// The session being recorded, persisted so it survives an app kill.
class SessionState {
  SessionState({
    required this.id,
    required this.startedAt,
    required this.lastActive,
    required this.sampled,
    this.seq = 0,
    this.created = false,
    this.backgroundedAt,
  });

  final String id;
  final DateTime startedAt;
  DateTime lastActive;

  /// Decided once, before anything is recorded.
  final bool sampled;

  /// Next batch sequence number (batch_id = `<id>-<seq>`).
  int seq;

  /// Whether the create-session request was queued.
  bool created;

  /// When the app went to the background, if it is there.
  DateTime? backgroundedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'started_at': startedAt.millisecondsSinceEpoch,
    'last_active': lastActive.millisecondsSinceEpoch,
    'sampled': sampled,
    'seq': seq,
    'created': created,
    'backgrounded_at': backgroundedAt?.millisecondsSinceEpoch,
  };

  static SessionState fromJson(Map<String, Object?> j) {
    DateTime t(Object? v) =>
        DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
    return SessionState(
      id: j['id'] as String,
      startedAt: t(j['started_at']),
      lastActive: t(j['last_active']),
      sampled: j['sampled'] as bool? ?? true,
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      created: j['created'] as bool? ?? false,
      backgroundedAt: j['backgrounded_at'] == null
          ? null
          : t(j['backgrounded_at']),
    );
  }
}

/// SDK state on disk: consent and the current session.
class StateStore {
  StateStore(this.file);

  final File? file;

  bool optedOut = false;
  SessionState? session;
  String? userId;
  Map<String, String> traits = {};

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      final j = (jsonDecode(await f.readAsString()) as Map)
          .cast<String, Object?>();
      optedOut = j['opted_out'] as bool? ?? false;
      final s = j['session'];
      session = s is Map ? SessionState.fromJson(s.cast()) : null;
      userId = j['user_id'] as String?;
      traits = ((j['traits'] as Map?) ?? const {}).map(
        (k, v) => MapEntry('$k', '$v'),
      );
    } catch (e) {
      log('ignoring unreadable state: $e');
    }
  }

  Future<void> _saving = Future.value();

  /// Writes the state; saves run one at a time.
  Future<void> save() => _saving = _saving.then((_) => _save());

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'opted_out': optedOut,
          'session': session?.toJson(),
          'user_id': userId,
          'traits': traits,
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      log('could not save state: $e');
    }
  }
}

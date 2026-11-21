import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:http/http.dart' as http;

import '../util/log.dart';
import 'outbox.dart';

/// What the uploader does with a response (Recording API v1, "Errors and
/// retries").
enum UploadDecision { done, drop, unauthorized, split, retryAfter, backoff }

UploadDecision decide(int status) {
  if (status >= 200 && status < 300) return UploadDecision.done;
  if (status == 401 || status == 403) return UploadDecision.unauthorized;
  if (status == 413) return UploadDecision.split;
  if (status == 429) return UploadDecision.retryAfter;
  if (status >= 500) return UploadDecision.backoff;
  return UploadDecision.drop; // 400 and other 4xx: retrying won't help
}

/// Backoff for the n-th consecutive failure (0-based): 1 s, 2 s, 4 s ... 60 s.
Duration backoffFor(int failures) =>
    Duration(seconds: min(60, 1 << min(failures, 6)));

/// Sends queued requests one at a time, oldest first.
class Uploader {
  Uploader({
    required this.outbox,
    required this.endpoint,
    required this.key,
    required this.sdk,
    http.Client? client,
    this.onUnauthorized,
    this.onAssetStored,
    Future<void> Function(Duration)? delay,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _delay = delay ?? Future<void>.delayed;

  final Outbox outbox;

  /// Ingest base URL, e.g. `https://ingest.replayiq.example`.
  final Uri endpoint;
  final String key;
  final String sdk;
  final Duration timeout;

  /// Called once on 401/403; the SDK stops recording for this app run.
  final void Function()? onUnauthorized;

  /// Called with an asset's hash once the server has it.
  final void Function(String hash)? onAssetStored;

  final http.Client _client;
  final Future<void> Function(Duration) _delay;

  bool _draining = false;
  bool _stopped = false;
  bool _waiting = false;
  int _failures = 0;
  final Set<int> _loggedStatuses = {};
  Completer<void>? _drained;

  bool get isStopped => _stopped;

  /// True while waiting out a backoff or Retry-After.
  bool get isWaiting => _waiting;

  /// Sends everything queued. Concurrent calls share one run; a call during
  /// a backoff returns when that run ends.
  Future<void> drain() {
    if (_stopped) return Future.value();
    if (_draining) return _drained!.future;
    _draining = true;
    _drained = Completer<void>();
    _run().whenComplete(() {
      _draining = false;
      _drained!.complete();
    });
    return _drained!.future;
  }

  void stop() => _stopped = true;

  Future<void> _run() async {
    while (!_stopped) {
      final item = outbox.first;
      if (item == null) return;
      Duration? wait;
      try {
        final res = await _send(item);
        switch (decide(res.statusCode)) {
          case UploadDecision.done:
            _failures = 0;
            if (item.assetHash != null) onAssetStored?.call(item.assetHash!);
            await outbox.remove(item);
          case UploadDecision.drop:
            _failures = 0;
            if (_loggedStatuses.add(res.statusCode)) {
              log('${item.path} rejected (${res.statusCode}): ${res.body}');
            }
            await outbox.remove(item);
          case UploadDecision.unauthorized:
            log('ingest key rejected (${res.statusCode}); recording stopped');
            _stopped = true;
            onUnauthorized?.call();
            return;
          case UploadDecision.split:
            if (item.kind == RequestKind.events) {
              if (!await outbox.split(item)) log('event too large, dropped');
            } else {
              await outbox.remove(item);
            }
          case UploadDecision.retryAfter:
            wait = _retryAfter(res.headers['retry-after']);
          case UploadDecision.backoff:
            wait = backoffFor(_failures++);
        }
      } catch (e) {
        log('upload failed: $e');
        wait = backoffFor(_failures++);
      }
      if (wait != null) {
        _waiting = true;
        try {
          await _delay(wait);
        } finally {
          _waiting = false;
        }
      }
    }
  }

  Uri _url(String path) => endpoint.replace(
    path: '${endpoint.path.replaceAll(RegExp(r'/+$'), '')}$path',
  );

  Future<http.Response> _send(OutboxItem item) async {
    if (item.kind == RequestKind.asset) return _sendAsset(item);
    final body = await outbox.readBody(item);
    final url = _url(item.path);
    return _client
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
            'Content-Encoding': 'gzip',
            'User-Agent': sdk,
          },
          body: body,
        )
        .timeout(timeout);
  }

  /// `HEAD /api/v1/assets/<hash>`, then `POST` the raw bytes if the
  /// server doesn't have them.
  Future<http.Response> _sendAsset(OutboxItem item) async {
    final hash = item.assetHash!;
    final head = await _client
        .head(
          _url('${item.path}/$hash'),
          headers: {'Authorization': 'Bearer $key', 'User-Agent': sdk},
        )
        .timeout(timeout);
    if (head.statusCode == 200) return head;
    final body = await outbox.readBody(item);
    return _client
        .post(
          _url(item.path),
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': item.contentType ?? 'application/octet-stream',
            'X-Asset-Hash': hash,
            'User-Agent': sdk,
          },
          body: body,
        )
        .timeout(timeout);
  }

  Duration _retryAfter(String? header) {
    final s = int.tryParse(header?.trim() ?? '');
    if (s != null && s >= 0) return Duration(seconds: min(s, 600));
    if (header != null) {
      try {
        final d = HttpDate.parse(header).difference(DateTime.now());
        if (!d.isNegative) return d;
      } catch (_) {}
    }
    return backoffFor(_failures++);
  }

  void close() => _client.close();
}

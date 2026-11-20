import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../util/log.dart';

/// Kinds of request, sent in the order they were queued.
enum RequestKind { createSession, events, endSession, asset }

/// A queued request. Its gzipped JSON body lives on disk next to a one-line
/// header, so it survives an app kill and is sent on the next launch.
class OutboxItem {
  OutboxItem({
    required this.file,
    required this.kind,
    required this.path,
    required this.events,
    required this.rawBytes,
    this.batchId,
    this.assetHash,
    this.contentType,
  });

  /// Asset requests: the sha256 of the (raw, not gzipped) body.
  final String? assetHash;
  final String? contentType;

  final File file;
  final RequestKind kind;

  /// API path, e.g. `/api/v1/events`.
  final String path;

  /// Number of events (events requests only).
  final int events;

  /// Decompressed body size.
  final int rawBytes;
  final String? batchId;

  String get name => file.uri.pathSegments.last;
}

/// Encoded once, off the UI thread when it is large.
class EncodedBody {
  EncodedBody(this.gzipped, this.rawBytes);
  final Uint8List gzipped;
  final int rawBytes;
}

Future<EncodedBody> encodeBody(Map<String, Object?> body) async {
  EncodedBody run() {
    final raw = utf8.encode(jsonEncode(body));
    return EncodedBody(Uint8List.fromList(gzip.encode(raw)), raw.length);
  }

  final events = body['events'];
  final large = events is List && events.any(_isScreen);
  return large ? Isolate.run(run) : run();
}

bool _isScreen(Object? e) => e is Map && e['subtype'] == 'screen';

Map<String, Object?> decodeBody(Uint8List gzipped) =>
    (jsonDecode(utf8.decode(gzip.decode(gzipped))) as Map)
        .cast<String, Object?>();

/// FIFO of API requests persisted to a directory.
///
/// Budget (spec): at most ~5 MB / 1000 events of unsent batches; the oldest
/// events batches are dropped first. Session create/end requests are small
/// and never dropped.
class Outbox {
  Outbox(this.dir, {this.maxRawBytes = 5 << 20, this.maxEvents = 1000});

  final Directory dir;
  final int maxRawBytes;
  final int maxEvents;

  final List<OutboxItem> _items = [];
  int _seq = 0;
  Future<void> _lock = Future.value();

  List<OutboxItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  OutboxItem? get first => _items.isEmpty ? null : _items.first;

  /// Reads what a previous run left behind.
  Future<void> load() => _locked(() async {
    _items.clear();
    if (!await dir.exists()) await dir.create(recursive: true);
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.req')) files.add(e);
      if (e is File && e.path.endsWith('.tmp')) {
        await _delete(e); // half-written by a killed app
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      try {
        final item = await _readHeader(f);
        _items.add(item);
        final n = int.tryParse(item.name.split('.').first) ?? 0;
        if (n >= _seq) _seq = n + 1;
      } catch (e) {
        log('dropping unreadable queued request ${f.path}: $e');
        await _delete(f);
      }
    }
  });

  /// Queues a request. [body] is encoded and gzipped here.
  Future<OutboxItem> add(
    RequestKind kind,
    String path,
    Map<String, Object?> body,
  ) async {
    final encoded = await encodeBody(body);
    return _locked(() => _write(kind, path, body, encoded));
  }

  Future<OutboxItem> _write(
    RequestKind kind,
    String path,
    Map<String, Object?> body,
    EncodedBody encoded, {
    int? at,
    String? assetHash,
    String? contentType,
  }) async {
    final events = body['events'];
    final header = <String, Object?>{
      'kind': kind.name,
      'path': path,
      'events': events is List ? events.length : 0,
      'raw_bytes': encoded.rawBytes,
      'batch_id': ?body['batch_id'] as String?,
      'hash': ?assetHash,
      'type': ?contentType,
    };
    final name = '${(_seq++).toString().padLeft(12, '0')}.req';
    final file = File('${dir.path}/$name');
    final tmp = File('${file.path}.tmp');
    final bytes = BytesBuilder(copy: false)
      ..add(utf8.encode(jsonEncode(header)))
      ..addByte(0x0a)
      ..add(encoded.gzipped);
    await tmp.writeAsBytes(bytes.takeBytes(), flush: true);
    await tmp.rename(file.path);
    final item = OutboxItem(
      file: file,
      kind: kind,
      path: path,
      events: header['events'] as int,
      rawBytes: encoded.rawBytes,
      batchId: header['batch_id'] as String?,
      assetHash: assetHash,
      contentType: contentType,
    );
    queuedBytes[kind] = (queuedBytes[kind] ?? 0) + encoded.gzipped.length;
    if (at != null) {
      _items.insert(at, item);
    } else {
      _items.add(item);
    }
    await _enforceBudget();
    return item;
  }

  /// Queues an asset upload (`POST /api/v1/assets`). Its body is sent
  /// as is, not as gzipped JSON.
  Future<OutboxItem> addAsset(
    String hash,
    Uint8List bytes,
    String contentType,
  ) => _locked(
    () => _write(
      RequestKind.asset,
      '/api/v1/assets',
      const {},
      EncodedBody(bytes, bytes.length),
      assetHash: hash,
      contentType: contentType,
    ),
  );

  /// Bytes written per request kind since start (what goes over the wire;
  /// for measurement).
  final Map<RequestKind, int> queuedBytes = {};

  /// The body of [item] as it goes on the wire: gzipped JSON, or an
  /// asset's raw bytes.
  Future<Uint8List> readBody(OutboxItem item) async {
    final bytes = await item.file.readAsBytes();
    final nl = bytes.indexOf(0x0a);
    return Uint8List.sublistView(bytes, nl + 1);
  }

  Future<void> remove(OutboxItem item) => _locked(() async {
    _items.remove(item);
    await _delete(item.file);
  });

  /// Replaces an events request the server found too large (413) with two
  /// halves, each with its own `batch_id`. Returns false when it holds a
  /// single event, which can't be split (the item is dropped).
  Future<bool> split(OutboxItem item) async {
    final body = decodeBody(await readBody(item));
    final events = (body['events'] as List?) ?? const [];
    if (events.length < 2) {
      await remove(item);
      return false;
    }
    final mid = events.length ~/ 2;
    final id = body['batch_id'] as String? ?? 'batch';
    final halves = [
      {...body, 'batch_id': '${id}a', 'events': events.sublist(0, mid)},
      {
        ...body,
        'batch_id': '${id}b',
        'events': events.sublist(mid),
        'custom_events': const [],
      },
    ];
    final encoded = [for (final h in halves) await encodeBody(h)];
    await _locked(() async {
      var at = _items.indexOf(item);
      if (at < 0) return;
      _items.removeAt(at);
      await _delete(item.file);
      for (var i = 0; i < 2; i++) {
        await _write(item.kind, item.path, halves[i], encoded[i], at: at++);
      }
    });
    return true;
  }

  /// Deletes everything (opt-out).
  Future<void> clear() => _locked(() async {
    for (final i in _items) {
      await _delete(i.file);
    }
    _items.clear();
  });

  Future<void> _enforceBudget() async {
    var bytes = 0, events = 0;
    for (final i in _items) {
      bytes += i.rawBytes;
      events += i.events;
    }
    while (bytes > maxRawBytes || events > maxEvents) {
      final oldest = _items
          .where(
            (i) => i.kind == RequestKind.events || i.kind == RequestKind.asset,
          )
          .firstOrNull;
      if (oldest == null) break;
      // Keep the newest batch even when it alone is over budget.
      if (identical(
        oldest,
        _items.lastWhere(
          (i) => i.kind == RequestKind.events || i.kind == RequestKind.asset,
        ),
      )) {
        break;
      }
      _items.remove(oldest);
      bytes -= oldest.rawBytes;
      events -= oldest.events;
      log('buffer full: dropped batch ${oldest.batchId}');
      await _delete(oldest.file);
    }
  }

  Future<OutboxItem> _readHeader(File f) async {
    final raf = await f.open();
    try {
      final head = await raf.read(4096);
      final nl = head.indexOf(0x0a);
      if (nl < 0) throw const FormatException('no header');
      final h = jsonDecode(utf8.decode(head.sublist(0, nl))) as Map;
      return OutboxItem(
        file: f,
        kind: RequestKind.values.byName(h['kind'] as String),
        path: h['path'] as String,
        events: (h['events'] as num?)?.toInt() ?? 0,
        rawBytes: (h['raw_bytes'] as num?)?.toInt() ?? 0,
        batchId: h['batch_id'] as String?,
        assetHash: h['hash'] as String?,
        contentType: h['type'] as String?,
      );
    } finally {
      await raf.close();
    }
  }

  Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  Future<T> _locked<T>(Future<T> Function() fn) {
    final result = _lock.then((_) => fn());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }
}

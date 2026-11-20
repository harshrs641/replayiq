import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replayiq_flutter/src/transport/outbox.dart';
import 'package:replayiq_flutter/src/transport/uploader.dart';

Map<String, Object?> batch(String id, int n, {String session = 's1'}) => {
  'session_id': session,
  'batch_id': id,
  'device_masked': true,
  'events': [
    for (var i = 0; i < n; i++) {'type': 5, 'subtype': 'click', 'timestamp': i},
  ],
};

Map<String, Object?> decodeRequest(http.Request r) =>
    (jsonDecode(utf8.decode(gzip.decode(r.bodyBytes))) as Map)
        .cast<String, Object?>();

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('riq_outbox');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('Outbox', () {
    test('queued requests survive a restart, in order', () async {
      final a = Outbox(dir);
      await a.load();
      await a.add(RequestKind.createSession, '/api/v1/sessions', {
        'session_id': 's1',
      });
      await a.add(RequestKind.events, '/api/v1/events', batch('s1-000000', 3));

      final b = Outbox(dir); // a new app launch
      await b.load();
      expect(b.items.map((i) => i.kind), [
        RequestKind.createSession,
        RequestKind.events,
      ]);
      expect(b.items.last.batchId, 's1-000000');
      expect(b.items.last.events, 3);
      final body = decodeBody(await b.readBody(b.items.last));
      expect((body['events'] as List).length, 3);

      await b.add(RequestKind.events, '/api/v1/events', batch('s1-000001', 1));
      expect(b.items.last.name.compareTo(b.items[1].name), greaterThan(0));
    });

    test('drops the oldest batches beyond the event budget', () async {
      final o = Outbox(dir, maxEvents: 10);
      await o.load();
      await o.add(RequestKind.createSession, '/api/v1/sessions', {});
      for (var i = 0; i < 4; i++) {
        await o.add(RequestKind.events, '/api/v1/events', batch('b$i', 4));
      }
      expect(o.items.first.kind, RequestKind.createSession);
      expect(
        o.items
            .where((i) => i.kind == RequestKind.events)
            .map((i) => i.batchId),
        ['b2', 'b3'],
      );
      expect(dir.listSync().length, 3);
    });

    test('split replaces a batch with two halves in its place', () async {
      final o = Outbox(dir);
      await o.load();
      final big = await o.add(
        RequestKind.events,
        '/api/v1/events',
        batch('x', 5),
      );
      await o.add(RequestKind.endSession, '/api/v1/sessions/s1/end', {});
      expect(await o.split(big), isTrue);
      expect(o.items.map((i) => i.batchId), ['xa', 'xb', null]);
      expect(o.items.map((i) => i.events).take(2), [2, 3]);
    });

    test('ignores half-written files', () async {
      await File('${dir.path}/000000000009.req.tmp').writeAsString('junk');
      await File('${dir.path}/000000000010.req').writeAsString('junk');
      final o = Outbox(dir);
      await o.load();
      expect(o.isEmpty, isTrue);
    });
  });

  group('Uploader', () {
    late Outbox outbox;
    late List<http.Request> sent;
    late List<Duration> waits;

    Uploader uploader(
      Future<http.Response> Function(http.Request) handler, {
      void Function()? onUnauthorized,
    }) => Uploader(
      outbox: outbox,
      endpoint: Uri.parse('https://ingest.example.com/base/'),
      key: 'proj_key',
      sdk: 'replayiq-flutter/test',
      client: MockClient((r) {
        sent.add(r);
        return handler(r);
      }),
      delay: (d) async => waits.add(d),
      onUnauthorized: onUnauthorized,
    );

    setUp(() async {
      outbox = Outbox(dir);
      await outbox.load();
      sent = [];
      waits = [];
    });

    test('sends gzipped JSON with the Bearer key, oldest first', () async {
      await outbox.add(RequestKind.createSession, '/api/v1/sessions', {
        'session_id': 's1',
      });
      await outbox.add(
        RequestKind.events,
        '/api/v1/events',
        batch('s1-000000', 2),
      );
      await uploader((_) async => http.Response('{}', 202)).drain();

      expect(sent.map((r) => r.url.toString()), [
        'https://ingest.example.com/base/api/v1/sessions',
        'https://ingest.example.com/base/api/v1/events',
      ]);
      final r = sent.last;
      expect(r.headers['Authorization'], 'Bearer proj_key');
      expect(r.headers['Content-Encoding'], 'gzip');
      expect(r.headers['Content-Type'], startsWith('application/json'));
      expect(decodeRequest(r)['batch_id'], 's1-000000');
      expect(outbox.isEmpty, isTrue);
    });

    test('5xx and network errors retry the same batch with backoff', () async {
      await outbox.add(
        RequestKind.events,
        '/api/v1/events',
        batch('s1-000007', 1),
      );
      var calls = 0;
      await uploader((_) async {
        calls++;
        if (calls == 1) throw const SocketException('offline');
        if (calls < 4) return http.Response('oops', 503);
        return http.Response('{}', 202);
      }).drain();

      expect(sent.map((r) => decodeRequest(r)['batch_id']).toSet(), {
        's1-000007',
      });
      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(outbox.isEmpty, isTrue);
    });

    test('backoff is capped at 60 s', () {
      expect(backoffFor(0), const Duration(seconds: 1));
      expect(backoffFor(5), const Duration(seconds: 32));
      expect(backoffFor(6), const Duration(seconds: 60));
      expect(backoffFor(40), const Duration(seconds: 60));
    });

    test('429 waits Retry-After seconds', () async {
      await outbox.add(RequestKind.events, '/api/v1/events', batch('b', 1));
      var calls = 0;
      await uploader((_) async {
        calls++;
        return calls == 1
            ? http.Response('slow down', 429, headers: {'retry-after': '7'})
            : http.Response('{}', 202);
      }).drain();
      expect(waits, [const Duration(seconds: 7)]);
      expect(outbox.isEmpty, isTrue);
    });

    test('400 drops the batch and moves on', () async {
      await outbox.add(RequestKind.events, '/api/v1/events', batch('bad', 1));
      await outbox.add(RequestKind.events, '/api/v1/events', batch('good', 1));
      await uploader(
        (r) async => decodeRequest(r)['batch_id'] == 'bad'
            ? http.Response('invalid body', 400)
            : http.Response('{}', 202),
      ).drain();
      expect(sent.length, 2);
      expect(outbox.isEmpty, isTrue);
      expect(waits, isEmpty);
    });

    test('401/403 stops uploading and reports it', () async {
      await outbox.add(RequestKind.events, '/api/v1/events', batch('a', 1));
      await outbox.add(RequestKind.events, '/api/v1/events', batch('b', 1));
      var told = false;
      final u = uploader(
        (_) async => http.Response('revoked', 403),
        onUnauthorized: () => told = true,
      );
      await u.drain();
      expect(told, isTrue);
      expect(u.isStopped, isTrue);
      expect(sent.length, 1);
      await u.drain();
      expect(sent.length, 1);
    });

    test('413 splits the batch and resends both halves', () async {
      await outbox.add(RequestKind.events, '/api/v1/events', batch('big', 4));
      await uploader(
        (r) async => (decodeRequest(r)['events'] as List).length > 2
            ? http.Response('too large', 413)
            : http.Response('{}', 202),
      ).drain();
      expect(sent.map((r) => decodeRequest(r)['batch_id']), [
        'big',
        'biga',
        'bigb',
      ]);
      expect(outbox.isEmpty, isTrue);
    });

    test('assets: HEAD first, POST the raw bytes only when missing', () async {
      final bytes = Uint8List.fromList(List.generate(300, (i) => i % 256));
      await outbox.addAsset('a' * 64, bytes, 'image/png');
      await outbox.addAsset('b' * 64, bytes, 'image/jpeg');
      await outbox.add(RequestKind.events, '/api/v1/events', batch('e', 1));
      final stored = <String>[];
      await Uploader(
        outbox: outbox,
        endpoint: Uri.parse('https://ingest.example.com'),
        key: 'k',
        sdk: 'test',
        client: MockClient((r) async {
          sent.add(r);
          if (r.method == 'HEAD') {
            return http.Response('', r.url.path.endsWith('b' * 64) ? 200 : 404);
          }
          return http.Response(
            '{}',
            r.url.path == '/api/v1/assets' ? 201 : 202,
          );
        }),
        delay: (d) async => waits.add(d),
        onAssetStored: stored.add,
      ).drain();

      expect(sent.map((r) => '${r.method} ${r.url.path}'), [
        'HEAD /api/v1/assets/${'a' * 64}',
        'POST /api/v1/assets',
        'HEAD /api/v1/assets/${'b' * 64}',
        'POST /api/v1/events', // the batch goes after its assets
      ]);
      final post = sent[1];
      expect(post.headers['X-Asset-Hash'], 'a' * 64);
      expect(post.headers['Content-Type'], 'image/png');
      expect(post.headers['Content-Encoding'], isNull);
      expect(post.bodyBytes, bytes);
      expect(stored, ['a' * 64, 'b' * 64]);
      expect(outbox.isEmpty, isTrue);
    });

    test('decide follows the API table', () {
      expect(decide(201), UploadDecision.done);
      expect(decide(202), UploadDecision.done);
      expect(decide(400), UploadDecision.drop);
      expect(decide(401), UploadDecision.unauthorized);
      expect(decide(403), UploadDecision.unauthorized);
      expect(decide(413), UploadDecision.split);
      expect(decide(429), UploadDecision.retryAfter);
      expect(decide(500), UploadDecision.backoff);
      expect(decide(503), UploadDecision.backoff);
    });
  });
}

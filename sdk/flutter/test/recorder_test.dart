import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replayiq_flutter/src/session/recorder.dart';
import 'package:replayiq_flutter/src/session/state_store.dart';
import 'package:replayiq_flutter/src/transport/outbox.dart';
import 'package:replayiq_flutter/src/transport/uploader.dart';

/// One app launch against a fake server.
class Harness {
  Harness(this.dir, this.server, {this.sampleRate = 1.0});

  final Directory dir;
  final FakeServer server;
  final double sampleRate;
  DateTime now = DateTime.utc(2026, 11, 19, 10);
  late Recorder recorder;
  late Outbox outbox;
  late StateStore store;

  Future<Recorder> launch() async {
    outbox = Outbox(Directory('${dir.path}/outbox'));
    await outbox.load();
    store = StateStore(File('${dir.path}/state.json'));
    await store.load();
    final uploader = Uploader(
      outbox: outbox,
      endpoint: Uri.parse('http://ingest.test'),
      key: 'k',
      sdk: 'replayiq-flutter/test',
      client: MockClient(server.handle),
      delay: (_) async {},
      onUnauthorized: () => recorder.onUnauthorized(),
    );
    recorder = Recorder(
      outbox: outbox,
      uploader: uploader,
      store: store,
      device: const DeviceInfo(
        bundleId: 'com.acme.shop',
        os: 'ios',
        osVersion: '26.1',
        device: 'iPhone17,3',
        appVersion: '4.2.0 (318)',
      ),
      sdk: 'replayiq-flutter/test',
      sampleRate: sampleRate,
      flushInterval: const Duration(hours: 1), // flushed by hand
      screenSize: () => (width: 393, height: 852),
      currentRoute: () => 'checkout',
      now: () => now,
      random: Random(1),
    );
    await recorder.start();
    await settle();
    return recorder;
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await recorder.uploader.drain();
  }
}

class FakeServer {
  final List<(String path, Map<String, Object?> body)> requests = [];
  int status = 202;

  Future<http.Response> handle(http.Request r) async {
    requests.add((
      r.url.path,
      (jsonDecode(utf8.decode(gzip.decode(r.bodyBytes))) as Map).cast(),
    ));
    return http.Response('{}', status);
  }

  List<String> get paths => [for (final r in requests) r.$1];
  List<Map<String, Object?>> bodies(String path) => [
    for (final r in requests)
      if (r.$1 == path) r.$2,
  ];
}

Map<String, Object?> click(String selector) => {
  'type': 5,
  'subtype': 'click',
  'selector': selector,
};

void main() {
  late Directory dir;
  late FakeServer server;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('riq_recorder');
    server = FakeServer();
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'creates the session before its first batch, then sends batches',
    () async {
      final h = Harness(dir, server);
      final r = await h.launch();
      r.identify('user_123', {'plan': 'pro'});
      r.record(click('button:"Pay"'));
      r.track('checkout_started', {'items': 2});
      await r.flush();
      await h.settle();

      expect(server.paths, ['/api/v1/sessions', '/api/v1/events']);
      final s = server.bodies('/api/v1/sessions').single;
      expect(s['session_id'], r.session!.id);
      expect(s['user_id'], 'user_123');
      expect(s['url'], 'app://com.acme.shop/checkout');
      expect(s['screen_width'], 393);
      expect(s['sdk_version'], 'replayiq-flutter/test');
      expect(s['metadata'], {
        'plan': 'pro',
        'platform': 'flutter',
        'os': 'ios',
        'os_version': '26.1',
        'app_version': '4.2.0 (318)',
        'device': 'iPhone17,3',
      });

      final b = server.bodies('/api/v1/events').single;
      expect(b['batch_id'], '${r.session!.id}-000000');
      expect(b['device_masked'], true);
      expect(b['platform'], 'flutter');
      expect(
        (b['events'] as List).single,
        containsPair('selector', 'button:"Pay"'),
      );
      expect(
        (b['custom_events'] as List).single,
        containsPair('name', 'checkout_started'),
      );

      r.record(click('x'));
      await r.flush();
      await h.settle();
      expect(server.paths.last, '/api/v1/events'); // no second create
      expect(
        server.bodies('/api/v1/events').last['batch_id'],
        '${r.session!.id}-000001',
      );
    },
  );

  test('events are sorted by timestamp within a batch', () async {
    final h = Harness(dir, server);
    final r = await h.launch();
    r.record({'type': 5, 'subtype': 'touch', 'timestamp': 30});
    r.record({'type': 5, 'subtype': 'screen', 'timestamp': 10, 'image': 'x'});
    await r.flush();
    await h.settle();
    final events = server.bodies('/api/v1/events').single['events'] as List;
    expect(events.map((e) => (e as Map)['timestamp']), [10, 30]);
  });

  test('flushes on its own at 50 events', () async {
    final h = Harness(dir, server);
    final r = await h.launch();
    for (var i = 0; i < 50; i++) {
      r.record(click('b$i'));
    }
    await h.settle();
    expect(
      (server.bodies('/api/v1/events').single['events'] as List).length,
      50,
    );
  });

  test('an unsampled session sends nothing', () async {
    final h = Harness(dir, server, sampleRate: 0);
    final r = await h.launch();
    r.record(click('x'));
    await r.flush();
    await h.settle();
    expect(r.isRecording, isFalse);
    expect(r.capturing.value, isFalse);
    expect(server.requests, isEmpty);
  });

  test(
    'optOut drops everything and persists; optIn starts a new session',
    () async {
      final h = Harness(dir, server);
      server.status = 503; // keep things queued
      final r = await h.launch();
      r.record(click('x'));
      await r.flush();
      await r.optOut();
      expect(h.outbox.isEmpty, isTrue);
      r.record(click('y'));
      expect(r.bufferedEvents, 0);

      final h2 = Harness(dir, server);
      final r2 = await h2.launch(); // remembered across launches
      expect(r2.isRecording, isFalse);
      await r2.optIn();
      expect(r2.isRecording, isTrue);
      expect(r2.session, isNotNull);
    },
  );

  test(
    '30 min in the background ends the session; the next one is new',
    () async {
      final h = Harness(dir, server);
      final r = await h.launch();
      final first = r.session!.id;
      r.record(click('x'));
      await r.flush();
      await h.settle();

      final startedAt = h.now;
      h.now = h.now.add(const Duration(minutes: 2));
      r.onBackground();
      h.now = h.now.add(const Duration(minutes: 31));
      await r.onForeground();
      await h.settle();

      final end = server.bodies('/api/v1/sessions/$first/end').single;
      expect(end['duration_ms'], const Duration(minutes: 2).inMilliseconds);
      expect(
        DateTime.parse(end['ended_at'] as String),
        startedAt.add(const Duration(minutes: 2)),
      );
      expect(r.session!.id, isNot(first));
      expect(r.isRecording, isTrue);
    },
  );

  test('a short background keeps the session', () async {
    final h = Harness(dir, server);
    final r = await h.launch();
    final first = r.session!.id;
    r.onBackground();
    expect(r.capturing.value, isFalse);
    h.now = h.now.add(const Duration(minutes: 5));
    await r.onForeground();
    expect(r.session!.id, first);
    expect(r.capturing.value, isTrue);
  });

  test(
    'a relaunch soon after continues the session and its batch numbers',
    () async {
      final h = Harness(dir, server);
      final r = await h.launch();
      final id = r.session!.id;
      r.record(click('x'));
      await r.flush();
      await h.settle();

      final h2 = Harness(dir, server)
        ..now = h.now.add(const Duration(minutes: 3));
      final r2 = await h2.launch();
      expect(r2.session!.id, id);
      r2.record(click('y'));
      await r2.flush();
      await h2.settle();
      expect(server.bodies('/api/v1/events').last['batch_id'], '$id-000001');
    },
  );

  test(
    'a relaunch after 30 min ends the old session and starts another',
    () async {
      final h = Harness(dir, server);
      final r = await h.launch();
      final id = r.session!.id;
      r.record(click('x'));
      await r.flush();
      await h.settle();

      final h2 = Harness(dir, server)
        ..now = h.now.add(const Duration(hours: 2));
      final r2 = await h2.launch();
      expect(server.paths, contains('/api/v1/sessions/$id/end'));
      expect(r2.session!.id, isNot(id));
    },
  );

  test('batches queued while offline are sent on the next launch', () async {
    final h = Harness(dir, server);
    server.status = 503;
    final r = await h.launch();
    r.record(click('x'));
    await r.flush();
    r.uploader.stop(); // the app is killed
    final id = r.session!.id;

    server
      ..status = 202
      ..requests.clear();
    final h2 = Harness(dir, server)
      ..now = h.now.add(const Duration(minutes: 1));
    await h2.launch();
    expect(server.paths, ['/api/v1/sessions', '/api/v1/events']);
    expect(server.bodies('/api/v1/events').single['batch_id'], '$id-000000');
  });

  test('stop ends the session and records nothing until restart', () async {
    final h = Harness(dir, server);
    final r = await h.launch();
    final id = r.session!.id;
    r.record(click('x'));
    await r.stop();
    await h.settle();
    expect(server.paths, contains('/api/v1/sessions/$id/end'));
    r.record(click('y'));
    expect(r.bufferedEvents, 0);
    await r.restart();
    expect(r.session!.id, isNot(id));
    expect(r.isRecording, isTrue);
  });

  test('a rejected key stops recording', () async {
    final h = Harness(dir, server);
    server.status = 401;
    final r = await h.launch();
    var stopped = false;
    r.capturing.addListener(() => stopped = !r.capturing.value);
    r.record(click('x'));
    await r.flush();
    await h.settle();
    expect(stopped, isTrue);
    expect(r.isRecording, isFalse);
  });
}

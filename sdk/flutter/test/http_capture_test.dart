import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:replayiq_flutter/src/behaviour/http_capture.dart';

typedef Recorded = List<(String, Map<String, Object?>)>;

void main() {
  // Plain tests (no testWidgets): the widget-test binding replaces dart:io
  // HTTP with a mock that answers 400 to everything.
  group('HTTP capture', () {
    late HttpServer server;
    late Uri base;
    late Recorded events;
    late HttpRecorder recorder;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.statusCode = req.uri.path == '/prices' ? 404 : 200;
        req.response.close();
      });
      base = Uri.parse('http://127.0.0.1:${server.port}');
      events = [];
      recorder = HttpRecorder(
        (s, f) => events.add((s, f)),
        isOwnTraffic: (u) => u.path.startsWith('/api/v1/'),
      )..captureAll();
    });

    tearDown(() async {
      recorder.release();
      await server.close(force: true);
    });

    test('records dart:io and package:http requests once each', () async {
      final io = HttpClient();
      final req = await io.getUrl(base.replace(path: '/prices', query: 'x=1'));
      await (await req.close()).drain<void>();
      io.close();
      final client = recorder.client(); // must not double up
      await client.post(base.replace(path: '/pay'));
      client.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        events.map(
          (e) =>
              '${e.$2['method']} ${Uri.parse(e.$2['url'] as String).path} ${e.$2['status']}',
        ),
        ['GET /prices 404', 'POST /pay 200'],
      );
      expect(events.first.$2['duration'], isA<int>());
    });

    test('a request that never connects is status 0 with the error', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        http.get(Uri.parse('http://127.0.0.1:$port/down')),
        throwsA(anything),
      );
      final e = events.single.$2;
      expect(e['status'], 0);
      expect(e['error'], isNotEmpty);
    });

    test("ReplayIQ's own uploads are not recorded", () async {
      await http.post(base.replace(path: '/api/v1/events'));
      await http.get(base.replace(path: '/ok'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.map((e) => Uri.parse(e.$2['url'] as String).path), ['/ok']);
    });
  });
}

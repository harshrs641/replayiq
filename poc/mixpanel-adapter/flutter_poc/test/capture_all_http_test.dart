import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replayiq_mobile_poc/replayiq_companion.dart';

// Plain tests (no testWidgets): the widget-test binding replaces dart:io
// HTTP with a mock that answers 400 to everything.
void main() {
  late HttpServer server, adapter;
  late Uri base, adapterBase;
  late List<http.Request> uploads;
  late ReplayIQCompanion companion;
  HttpOverrides? before;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response.statusCode = req.uri.path == '/prices' ? 404 : 200;
      req.response.close();
    });
    base = Uri.parse('http://127.0.0.1:${server.port}');
    adapter = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter.listen((req) => req.response.close());
    adapterBase = Uri.parse('http://127.0.0.1:${adapter.port}');
    uploads = [];
    before = HttpOverrides.current;
    companion = ReplayIQCompanion(
      adapterUrl: adapterBase.toString(),
      token: 'demo',
      replayId: () => 'rp1',
      flushInterval: Duration.zero,
      transport: MockClient((req) async {
        uploads.add(req);
        return http.Response('{}', 200);
      }),
    )..captureAllHttp();
  });

  tearDown(() async {
    HttpOverrides.global = before;
    await server.close(force: true);
    await adapter.close(force: true);
  });

  Future<List<Map<String, dynamic>>> recorded() async {
    await companion.flush();
    if (uploads.isEmpty) return [];
    return ((jsonDecode(uploads.single.body) as Map)['events'] as List).cast<Map<String, dynamic>>();
  }

  test('records dart:io and package:http requests once each, with status and duration', () async {
    final io = HttpClient();
    final req = await io.getUrl(base.replace(path: '/prices', query: 'x=1'));
    await (await req.close()).drain<void>();
    io.close();

    // companion.httpClient() would record too; with captureAllHttp it must not double up.
    final client = companion.httpClient();
    await client.post(base.replace(path: '/pay'));
    client.close();

    final events = await recorded();
    expect(events.map((e) => '${e['method']} ${Uri.parse(e['url'] as String).path} ${e['status']}'),
        ['GET /prices 404', 'POST /pay 200']);
    expect(events.first['url'], endsWith('/prices?x=1'));
    expect(events.first['duration'], isA<int>());
  });

  test('records requests that never connect as status 0 with the error', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(http.get(Uri.parse('http://127.0.0.1:$port/down')), throwsA(anything));
    final e = (await recorded()).single;
    expect(e['status'], 0);
    expect(e['url'], 'http://127.0.0.1:$port/down');
    expect(e['error'], isNotEmpty);
  });

  test("skips the adapter's own traffic", () async {
    await http.post(adapterBase.replace(path: '/riq/events'));
    await http.post(adapterBase.replace(path: '/record')); // the replay SDK's uploads
    await http.get(adapterBase.replace(path: '/settings'));
    // Anything else on the same host is the app's own request.
    await http.get(adapterBase.replace(path: '/demo/prices'));
    await http.get(base.replace(path: '/ok'));
    expect((await recorded()).map((e) => Uri.parse(e['url'] as String).path), ['/demo/prices', '/ok']);
  });
}

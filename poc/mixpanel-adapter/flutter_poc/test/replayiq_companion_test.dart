import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:replayiq_mobile_poc/replayiq_companion.dart';

void main() {
  late List<http.Request> sent;
  late int status;
  late String? replay;
  late int clock;

  ReplayIQCompanion make({int maxBuffered = 1000}) => ReplayIQCompanion(
        adapterUrl: 'http://mac.local:9090/',
        token: 'demo',
        distinctId: 'u1',
        replayId: () => replay,
        flushInterval: Duration.zero, // flush by hand
        maxBuffered: maxBuffered,
        now: () => clock,
        transport: MockClient((req) async {
          sent.add(req);
          return http.Response('{}', status);
        }),
      );

  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  setUp(() {
    sent = [];
    status = 200;
    replay = 'rp1';
    clock = 1000;
  });

  test('flushes events to the adapter, grouped by replay id', () async {
    final c = make();
    c.log('hello');
    replay = 'rp2';
    clock = 2000;
    c.record('navigate', {'url': 'app://flutter/x'});
    await c.flush();

    expect(sent, hasLength(2));
    expect(sent.first.url.toString(), 'http://mac.local:9090/riq/events');
    expect(sent.first.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('demo:'))}');
    expect(body(sent[0])['replay_id'], 'rp1');
    expect(body(sent[0])['distinct_id'], 'u1');
    expect(body(sent[0])['events'], [
      {'subtype': 'console', 'timestamp': 1000, 'level': 'log', 'message': 'hello'},
    ]);
    expect(body(sent[1])['replay_id'], 'rp2');
    expect(c.pending, 0);
  });

  test('events from before recording started go with the first replay id', () async {
    replay = null;
    final c = make();
    c.log('early');
    await c.flush();
    expect(sent, isEmpty, reason: 'no replay id yet: keep the event');
    expect(c.pending, 1);
    replay = 'rp1';
    await c.flush();
    expect(body(sent.single)['replay_id'], 'rp1');
    expect(c.pending, 0);
  });

  test('keeps events when the adapter fails and retries on the next flush', () async {
    final c = make();
    c.log('a');
    status = 502;
    await c.flush();
    expect(c.pending, 1);
    status = 200;
    await c.flush();
    expect(c.pending, 0);
    expect(sent, hasLength(2));
  });

  test('drops the oldest events beyond maxBuffered', () async {
    final c = make(maxBuffered: 2);
    for (final m in ['1', '2', '3']) {
      c.log(m);
    }
    await c.flush();
    expect((body(sent.single)['events'] as List).map((e) => e['message']), ['2', '3']);
  });

  test('httpClient records status, duration and connection errors', () async {
    final c = make();
    final ok = c.httpClient(MockClient((_) async => http.Response('', 404)));
    await ok.get(Uri.parse('https://api.test/prices?x=1'));
    final broken = c.httpClient(MockClient((_) async => throw http.ClientException('Failed host lookup')));
    await expectLater(broken.post(Uri.parse('https://api.test/pay')), throwsA(isA<http.ClientException>()));
    await c.flush();

    final events = body(sent.single)['events'] as List;
    expect(events[0], containsPair('status', 404));
    expect(events[0], containsPair('method', 'GET'));
    expect(events[0], containsPair('url', 'https://api.test/prices?x=1'));
    expect(events[0]['duration'], isA<int>());
    expect(events[1], containsPair('status', 0));
    expect(events[1]['error'], contains('Failed host lookup'));
  });

  test('recordError keeps the message, stack and first app frame', () async {
    final c = make();
    final stack = StackTrace.fromString(
      '#0      Object.noSuchMethod (dart:core-patch/object_patch.dart:38:5)\n'
      '#1      _Checkout.apply (package:replayiq_mobile_poc/main.dart:142:7)\n',
    );
    c.recordError(StateError('no discount'), stack, context: 'widgets library');
    await c.flush();
    final e = (body(sent.single)['events'] as List).single as Map;
    expect(e['subtype'], 'js_error');
    expect(e['message'], 'widgets library: Bad state: no discount');
    expect(e['filename'], 'package:replayiq_mobile_poc/main.dart');
    expect(e['lineno'], 142);
    expect(e['colno'], 7);
    expect(e['stack'], contains('main.dart:142:7'));
  });

  test('runCapturingPrints records app prints but not the SDK log lines', () async {
    final c = make();
    c.runCapturingPrints(() {
      print('Checkout opened');
      print('[FINE] mixpanel.session_replay: captured frame');
      print('══╡ EXCEPTION CAUGHT BY GESTURE ╞═══════════════════════');
      print('The following StateError was thrown while handling a gesture:');
      print('#0      CheckoutScreen.build (package:app/main.dart:1:1)');
      print('════════════════════════════════════════════════════════');
      print('Prices request returned 404');
    });
    await c.flush();
    final events = body(sent.single)['events'] as List;
    expect(events.map((e) => e['message']), ['Checkout opened', 'Prices request returned 404']);
  });

  testWidgets('navigatorObserver records named screens, not dialogs', (tester) async {
    final c = make();
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, navigatorObservers: [c.navigatorObserver], home: const Text('home')));
    key.currentState!.push(MaterialPageRoute<void>(settings: const RouteSettings(name: '/order-summary'), builder: (_) => const Text('s')));
    await tester.pumpAndSettle();
    showDialog<void>(context: key.currentContext!, builder: (_) => const Text('dialog'));
    await tester.pumpAndSettle();
    key.currentState!.pop(); // dialog
    key.currentState!.pop(); // summary -> home
    await tester.pumpAndSettle();
    await c.flush();

    final urls = (body(sent.single)['events'] as List).map((e) => e['url']).toList();
    // The dialog's pop "returns" to the summary already showing: not repeated.
    expect(urls, ['app://flutter/', 'app://flutter/order-summary', 'app://flutter/']);
  });
}

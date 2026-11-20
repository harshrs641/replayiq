import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayiq_flutter/replayiq_flutter.dart';
import 'package:replayiq_flutter/src/behaviour/signals.dart';
import 'package:replayiq_flutter/src/nativedom/assets.dart';
import 'package:replayiq_flutter/src/nativedom/differ.dart';
import 'package:replayiq_flutter/src/nativedom/dom_recorder.dart';
import 'package:replayiq_flutter/src/nativedom/node.dart';
import 'package:replayiq_flutter/src/nativedom/walker.dart';

class FakeAssets implements AssetHashes {
  final Map<int, String> islands = {};
  String? image = 'img-hash';
  @override
  String? imageHash(ui.Image image, Size logicalSize) => this.image;
  @override
  String? islandHash(int nodeId) => islands[nodeId];
}

List<UiNode> all(UiNode root) {
  final out = <UiNode>[];
  root.visit((n, _) => out.add(n));
  return out;
}

UiNode textNode(UiNode root, String v) =>
    all(root).firstWhere((n) => n.k == 'text' && n.tx?['v'] == v);

void main() {
  late UiWalker walker;
  late FakeAssets assets;

  setUp(() {
    assets = FakeAssets();
    walker = UiWalker(assets: assets);
  });

  WalkResult walk(WidgetTester tester) =>
      walker.walk(tester.binding.renderViews.first.child!);

  group('walker', () {
    testWidgets('text carries its value and style; frames are local', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: EdgeInsets.only(left: 20, top: 30),
            child: Align(
              alignment: Alignment.topLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFF112233),
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Text(
                    'Total \$65.00',
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final r = walk(tester);
      final box = r.root.c.single;
      expect(box.k, 'view');
      expect(box.f.take(2), [20, 30]);
      expect(box.s, {
        'bg': '#FF112233',
        'r': [8, 8, 8, 8],
      });
      final text = box.c.single;
      expect(text.k, 'text');
      expect(text.f.take(2), [4, 4]); // relative to the box
      expect(text.tx, containsPair('v', 'Total \$65.00'));
      expect(text.tx, containsPair('size', 17));
      expect(text.tx, containsPair('w', 600));
      expect(text.tx, containsPair('col', '#FF111827'));
      expect(text.tx, containsPair('ml', 2));
      expect(text.tx, containsPair('al', 'left'));
    });

    testWidgets('rich text is sent as spans, first span style on top', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text.rich(
            TextSpan(
              text: 'Pay ',
              style: TextStyle(fontSize: 12),
              children: [
                TextSpan(
                  text: 'now',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      );
      final text = all(walk(tester).root).firstWhere((n) => n.k == 'text');
      final spans = text.tx!['spans'] as List;
      expect(spans.map((s) => (s as Map)['v']), ['Pay ', 'now']);
      expect((spans[1] as Map)['w'], 700);
      expect(text.tx!['size'], 12);
    });

    testWidgets('inputs never carry their value; password type', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: TextEditingController(text: 'Jane Doe')),
                TextField(
                  obscureText: true,
                  controller: TextEditingController(text: '4242'),
                ),
              ],
            ),
          ),
        ),
      );
      final r = walk(tester);
      final inputs = all(r.root).where((n) => n.k == 'input').toList();
      expect(inputs.map((n) => n.input!['type']), ['text', 'password']);
      final json = r.root.toJson().toString();
      expect(json, isNot(contains('Jane')));
      expect(json, isNot(contains('4242')));
    });

    testWidgets('ReplayIQMask is an empty mask node; maskAllText', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              ReplayIQMask(child: Text('secret@example.com')),
              Text('public'),
              ReplayIQUnmask(child: Text('kept')),
            ],
          ),
        ),
      );
      var r = walk(tester);
      final mask = all(r.root).firstWhere((n) => n.k == 'mask');
      expect(mask.c, isEmpty);
      expect(r.root.toJson().toString(), isNot(contains('secret')));

      walker = UiWalker(assets: assets, maskAllText: true);
      r = walk(tester);
      final texts = all(r.root).where((n) => n.k == 'text');
      expect(texts.map((n) => n.tx!['v']), ['kept']);
      expect(all(r.root).where((n) => n.k == 'mask'), hasLength(2));
    });

    testWidgets('a scaled widget gets a transform about its centre', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Transform.scale(
              scale: 2,
              child: const SizedBox(
                width: 50,
                height: 20,
                child: ColoredBox(color: Color(0xFFFF0000)),
              ),
            ),
          ),
        ),
      );
      final box = all(walk(tester).root).firstWhere((n) => n.s?['bg'] != null);
      expect(box.s!['t'], [2, 0, 0, 2, 0, 0]);
      // Centre stays at the screen centre (800x600 test surface).
      expect(box.f[0] + box.f[2] / 2, 400);
      expect(box.f[1] + box.f[3] / 2, 300);
    });

    testWidgets('custom painters are islands; images reference assets', (
      tester,
    ) async {
      final image = await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawColor(const Color(0xFF00FF00), BlendMode.src);
        return rec.endRecording().toImage(4, 4);
      });
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              CustomPaint(size: const Size(100, 50), painter: _Chart()),
              RawImage(image: image, width: 40, height: 40, fit: BoxFit.cover),
            ],
          ),
        ),
      );
      final r = walk(tester);
      final island = all(r.root).firstWhere((n) => n.k == 'island');
      expect(r.islands.single.id, island.id);
      expect(r.islands.single.rect.size, const Size(100, 50));
      final img = all(r.root).firstWhere((n) => n.k == 'image');
      expect(img.img, {'a': 'img-hash', 'fit': 'cover'});
    });

    testWidgets('ids are stable across walks', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('a'),
        ),
      );
      final a = textNode(walk(tester).root, 'a').id;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('b'),
        ),
      );
      expect(textNode(walk(tester).root, 'b').id, a);
    });
  });

  group('diff', () {
    testWidgets('scrolling changes only the scroll node so', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: controller,
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('Item $i')),
          ),
        ),
      );
      final before = flatten(walk(tester).root);
      controller.jumpTo(20);
      await tester.pump();
      final d = diffTrees(before, flatten(walk(tester).root));
      // Items entering the cache extent may be added; nothing on screen
      // moves: the only update is the scroll node's offset.
      expect(d.updates.single['k'], 'scroll');
      expect(d.updates.single['so'], [0, 20]);
      // Children keep content coordinates.
      expect(textNode(walk(tester).root, 'Item 2').f[1], 100);
    });

    testWidgets('scrolling far adds and removes list items', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: controller,
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('Item $i')),
          ),
        ),
      );
      final before = flatten(walk(tester).root);
      controller.jumpTo(2000);
      await tester.pump();
      final after = walk(tester).root;
      final d = diffTrees(before, flatten(after));
      expect(d.adds, isNotEmpty);
      expect(d.removes, isNotEmpty);
      final scrollId = all(after).firstWhere((n) => n.k == 'scroll').id;
      expect(d.adds.every((a) => a['p'] == scrollId), isTrue);
    });

    test('updates carry the complete node minus children', () {
      UiNode tree(String label, double x) {
        final root = UiNode(1, 'view', [0, 0, 100, 100]);
        final v = UiNode(2, 'view', [x, 0, 10, 10])..s = {'bg': '#FF000000'};
        v.c.add(UiNode(3, 'text', [0, 0, 10, 10])..tx = {'v': label});
        root.c.add(v);
        return root;
      }

      final d = diffTrees(flatten(tree('a', 0)), flatten(tree('b', 5)));
      expect(d.updates, hasLength(2));
      final view = d.updates.firstWhere((u) => u['id'] == 2);
      expect(view, {
        'id': 2,
        'k': 'view',
        'f': [5, 0, 10, 10],
        's': {'bg': '#FF000000'},
      });
      final text = d.updates.firstWhere((u) => u['id'] == 3);
      expect(text['k'], 'text');
      expect(text['tx'], {'v': 'b'});
      expect(text.containsKey('c'), isFalse);
    });

    test('adds name the next sibling; reorders are remove + add', () {
      UiNode tree(List<int> ids) {
        final root = UiNode(1, 'view', [0, 0, 1, 1]);
        for (final id in ids) {
          root.c.add(UiNode(id, 'view', [0, 0, 1, 1]));
        }
        return root;
      }

      var d = diffTrees(flatten(tree([2, 4])), flatten(tree([2, 3, 4, 5])));
      expect(d.adds.map((a) => [a['p'], a['next'], (a['n'] as Map)['id']]), [
        [1, null, 5],
        [1, 4, 3],
      ]);
      expect(d.removes, isEmpty);

      d = diffTrees(flatten(tree([2, 3, 4])), flatten(tree([4, 2, 3])));
      expect(d.removes, isNotEmpty);
      expect(d.adds, isNotEmpty);

      d = diffTrees(flatten(tree([2, 3, 4])), flatten(tree([2, 4])));
      expect(d.removes, [
        {'p': 1, 'id': 3},
      ]);
      expect(d.adds, isEmpty);
    });
  });

  test('island share decides the auto-mode fallback', () {
    final r = WalkResult(
      UiNode(1, 'view', [0, 0, 100, 100]),
      [IslandRef(2, const Rect.fromLTWH(0, 0, 100, 60), capturable: true)],
      {},
      2,
    );
    expect(r.islandAreaShare(const Size(100, 100)), closeTo(0.6, 1e-9));
  });

  group('DomRecorder', () {
    testWidgets('snapshot first, then mutations, snapshot again on demand', (
      tester,
    ) async {
      final events = <Map<String, Object?>>[];
      final counter = ValueNotifier(0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder(
            valueListenable: counter,
            builder: (_, v, _) => Text('count $v'),
          ),
        ),
      );
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('riq_dom'),
      );
      final manager = AssetManager(
        ledger: AssetLedger(File('${dir!.path}/a.txt')),
        upload: (_, _, _) async {},
        onChanged: () {},
        bundle: _EmptyBundle(),
      );
      final rec = DomRecorder(
        walker: UiWalker(assets: manager),
        assets: manager,
        emit: events.add,
        listenToFrames: false,
      );
      rec.start();
      rec.walkNow();
      counter.value = 1;
      await tester.pump();
      rec.walkNow();
      rec.walkNow(); // nothing changed: no event
      rec.markSnapshotNeeded();
      rec.walkNow();
      rec.stop();

      expect(events.map((e) => e['subtype']), [
        'ui_snapshot',
        'ui_mutation',
        'ui_snapshot',
      ]);
      final snap = events.first;
      expect(snap['width'], 800);
      expect(snap['density'], isA<double>());
      final update = (events[1]['updates'] as List).single as Map;
      expect(update['tx'], containsPair('v', 'count 1'));
      expect(update['k'], 'text');
      expect(rec.stats.walkMicros, hasLength(4));
    });
  });

  group('assets', () {
    test('the ledger remembers stored hashes across launches', () async {
      final dir = await Directory.systemTemp.createTemp('riq_ledger');
      final a = AssetLedger(File('${dir.path}/assets.txt'));
      await a.load();
      final h = sha256Hex([1, 2, 3]);
      await a.add(h);
      final b = AssetLedger(File('${dir.path}/assets.txt'));
      await b.load();
      expect(b.contains(h), isTrue);
      expect(h.length, 64);
    });

    test('island crops are uploaded once and update the node hash', () async {
      final uploads = <String>[];
      var changes = 0;
      var crop = Uint8List.fromList([1, 2, 3]);
      final m = AssetManager(
        ledger: AssetLedger(null),
        upload: (h, b, t) async => uploads.add('$t $h'),
        onChanged: () => changes++,
        captureRegions: (r) async => {for (final id in r.keys) id: crop},
        islandInterval: Duration.zero,
        bundle: _EmptyBundle(),
      );
      final islands = [
        IslandRef(7, const Rect.fromLTWH(0, 0, 10, 10), capturable: true),
        IslandRef(8, const Rect.fromLTWH(0, 0, 10, 10), capturable: false),
      ];
      await m.captureIslands(islands);
      await m.captureIslands(islands); // unchanged pixels
      expect(uploads, ['image/jpeg ${sha256Hex(crop)}']);
      expect(m.islandHash(7), sha256Hex(crop));
      expect(m.islandHash(8), isNull);
      expect(changes, 1);
      crop = Uint8List.fromList([4, 5, 6]);
      await m.captureIslands(islands);
      expect(uploads, hasLength(2));
      expect(changes, 2);
    });
  });

  group('signals', () {
    test('jank is reported per 5 s window with dropped and frozen frames', () {
      final events = <(String, Map<String, Object?>)>[];
      final s = SignalsRecorder(
        (k, f) => events.add((k, f)),
        screen: () => 'checkout',
      );
      final t0 = DateTime.now();
      s.addFrame(const Duration(milliseconds: 8), at: t0);
      s.addFrame(const Duration(milliseconds: 40), at: t0);
      s.addFrame(const Duration(milliseconds: 900), at: t0);
      s.addFrame(
        const Duration(milliseconds: 8),
        at: t0.add(const Duration(seconds: 6)),
      );
      final jank = events.single;
      expect(jank.$1, 'jank');
      expect(jank.$2['dropped'], 1);
      expect(jank.$2['frozen'], 1);
      expect(jank.$2['worst'], 900);
      expect(jank.$2['screen'], 'checkout');
      expect(s.totals.frames, 4);
    });

    test('lifecycle marks the first foreground as cold', () {
      final events = <Map<String, Object?>>[];
      final s = SignalsRecorder((_, f) => events.add(f), screen: () => null);
      s.lifecycle('foreground');
      s.lifecycle('background');
      s.lifecycle('foreground');
      expect(events.map((e) => e['cold']), [true, false, false]);
    });
  });
}

class _Chart extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), Paint());

  @override
  bool shouldRepaint(_Chart oldDelegate) => false;
}

class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw FlutterError('none');

  @override
  Future<String> loadString(String key, {bool cache = true}) async => '[]';
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayiq_flutter/replayiq_flutter.dart';
import 'package:replayiq_flutter/src/behaviour/selector.dart';

void main() {
  Future<String?> selectorFor(
    WidgetTester tester,
    Widget body,
    Finder target, {
    bool maskAllText = false,
    PreferredSizeWidget? appBar,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(appBar: appBar, body: body),
      ),
    );
    final at = tester.getCenter(target);
    return TapSelectorResolver(maskAllText: maskAllText).selectorAt(at);
  }

  testWidgets('a material button is named by its text', (tester) async {
    final s = await selectorFor(
      tester,
      Center(
        child: ElevatedButton(onPressed: () {}, child: const Text('Pay now')),
      ),
      find.text('Pay now'),
    );
    expect(s, 'button:"Pay now"');
  });

  testWidgets('a list tile is a listitem with all its text', (tester) async {
    final s = await selectorFor(
      tester,
      ListView(
        children: [
          ListTile(
            title: const Text('Item 3'),
            trailing: const Text(r'$15.00'),
            onTap: () {},
          ),
        ],
      ),
      find.text('Item 3'),
    );
    expect(s, r'listitem:"Item 3 $15.00"');
  });

  testWidgets('a text field is named by its label, never its value', (
    tester,
  ) async {
    final s = await selectorFor(
      tester,
      Center(
        child: TextField(
          controller: TextEditingController(text: '4242 4242'),
          decoration: const InputDecoration(labelText: 'Card number'),
        ),
      ),
      find.byType(EditableText),
    );
    expect(s, 'input:"Card number"');
  });

  testWidgets('an icon button uses its tooltip', (tester) async {
    final s = await selectorFor(
      tester,
      Center(
        child: IconButton(
          onPressed: () {},
          tooltip: 'Delete',
          icon: const Icon(Icons.delete),
        ),
      ),
      find.byIcon(Icons.delete),
    );
    expect(s, 'button:"Delete"');
  });

  testWidgets('the app bar back button is named Back', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      Scaffold(appBar: AppBar(title: const Text('Two'))),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final at = tester.getCenter(find.byType(BackButton));
    expect(TapSelectorResolver().selectorAt(at), 'button:"Back"');
  });

  testWidgets('inside ReplayIQMask only the role is sent', (tester) async {
    final s = await selectorFor(
      tester,
      Center(
        child: ReplayIQMask(
          child: ElevatedButton(onPressed: () {}, child: const Text('Secret')),
        ),
      ),
      find.text('Secret'),
    );
    expect(s, 'button');
  });

  testWidgets('maskAllText drops text labels unless unmasked', (tester) async {
    final masked = await selectorFor(
      tester,
      Center(
        child: ElevatedButton(onPressed: () {}, child: const Text('Pay')),
      ),
      find.text('Pay'),
      maskAllText: true,
    );
    expect(masked, 'button');
    final unmasked = await selectorFor(
      tester,
      Center(
        child: ReplayIQUnmask(
          child: ElevatedButton(onPressed: () {}, child: const Text('Pay')),
        ),
      ),
      find.text('Pay'),
      maskAllText: true,
    );
    expect(unmasked, 'button:"Pay"');
  });

  testWidgets(
    'tapping plain text sends only the role (its text may be personal)',
    (tester) async {
      final s = await selectorFor(
        tester,
        const Center(child: Text('Say "hi"')),
        find.text('Say "hi"'),
      );
      expect(s, 'text');
    },
  );
}

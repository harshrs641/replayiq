// Checkout demo recorded with replayiq_flutter.
//
//   flutter run --dart-define=RIQ_ENDPOINT=http://localhost:8080 --dart-define=RIQ_KEY=verify
//
// RIQ_ENDPOINT is the ReplayIQ ingest host (the gateway in ./dev.sh). From
// the Android emulator use http://10.0.2.2:8080; from a phone, your Mac's
// http://<name>.local:8080. RIQ_KEY is the project's ingest key (for now the
// project id).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:replayiq_flutter/replayiq_flutter.dart';

import 'autopilot.dart';

const endpoint = String.fromEnvironment(
  'RIQ_ENDPOINT',
  defaultValue: 'http://localhost:8080',
);
const key = String.fromEnvironment('RIQ_KEY', defaultValue: 'verify');

/// auto (default), nativeDom or screenshot.
const mode = String.fromEnvironment('RIQ_MODE', defaultValue: 'auto');

/// Seconds of scripted use to measure, 0 = off.
const autopilot = int.fromEnvironment('RIQ_AUTOPILOT');

/// A small generated picture, so the demo has an image asset.
Uint8List? productImage;

Future<Uint8List?> _makeImage() async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  const r = Rect.fromLTWH(0, 0, 96, 96);
  canvas.drawRect(
    r,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF6366F1), Color(0xFFEC4899)],
      ).createShader(r),
  );
  canvas.drawCircle(const Offset(48, 48), 22, Paint()..color = Colors.white);
  final image = await rec.endRecording().toImage(96, 96);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

// ReplayIQ.runZoned is optional: it adds print() output to the Console tab.
// Everything, binding initialization included, runs inside it, so Flutter
// sees a single zone.
void main() => ReplayIQ.runZoned(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReplayIQ.init(
    key: key,
    endpoint: endpoint,
    userId: 'demo_user_1',
    userTraits: {'plan': 'pro'},
    recordingMode: RecordingMode.values.byName(mode),
    debug: true,
  );
  productImage = await _makeImage();
  runApp(const DemoApp());
  if (autopilot > 0) runAutopilot(autopilot);
});

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReplayIQ Flutter demo',
      navigatorKey: navigatorKey,
      navigatorObservers: [ReplayIQ.navigatorObserver],
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      initialRoute: '/checkout',
      routes: {
        '/checkout': (_) => const CheckoutScreen(),
        '/order-summary': (_) => const SummaryScreen(),
      },
    );
  }
}

class CheckoutScreen extends StatelessWidget {
  const CheckoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            ReplayIQ.isRecording
                ? 'Recording session ${ReplayIQ.sessionId} to $endpoint'
                : 'Not recording',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // Text fields are always masked in the replay; the label isn't.
          if (productImage != null)
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(productImage!, width: 56, height: 56),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: 'Wireless earbuds  ',
                      children: [
                        TextSpan(
                          text: '\$65.00',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            key: nameKey,
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Full name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: cardController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Card number'),
          ),
          const SizedBox(height: 12),
          // Anything else sensitive: wrap it in ReplayIQMask.
          const ReplayIQMask(
            child: ListTile(
              leading: Icon(Icons.credit_card),
              title: Text('Saved card •••• 4242'),
              subtitle: Text('Expires 09/29'),
            ),
          ),
          const SizedBox(height: 24),
          // Does nothing visible: tap it 3-4 times quickly for a rage_click.
          ElevatedButton(
            key: payKey,
            onPressed: () => ReplayIQ.track('pay_tapped', {'amount': 42}),
            child: const Text('Pay now'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: summaryKey,
            onPressed: () => Navigator.of(context).pushNamed('/order-summary'),
            child: const Text('Order summary'),
          ),
          const SizedBox(height: 12),
          // Network tab: this path doesn't exist, so it is a 404.
          OutlinedButton(
            key: pricesKey,
            onPressed: () async {
              final res = await http.get(Uri.parse('$endpoint/demo/prices'));
              // ignore: avoid_print
              print('Prices request returned ${res.statusCode}');
            },
            child: const Text('Load prices (fails)'),
          ),
          const SizedBox(height: 12),
          // Console tab + AI analysis: an error thrown in a tap handler.
          OutlinedButton(
            onPressed: () =>
                throw StateError('Coupon service returned no discount'),
            child: const Text('Apply coupon (throws)'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              debugPrint('Flushing on request');
              ReplayIQ.flush();
            },
            child: const Text('Flush now'),
          ),
          TextButton(
            onPressed: ReplayIQ.stop,
            child: const Text('End session'),
          ),
        ],
      ),
    );
  }
}

class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order summary')),
      body: ListView(
        children: List.generate(
          20,
          (i) => ListTile(
            title: Text('Item ${i + 1}'),
            trailing: Text('\$${(i + 1) * 5}.00'),
            onTap: () {},
          ),
        ),
      ),
    );
  }
}

// POC app: Mixpanel's session replay SDK, pointed at the ReplayIQ adapter.
//
//   flutter run \
//     --dart-define=RIQ_URL=http://<your-mac>.local:9090 \
//     --dart-define=RIQ_PROJECT=demo
//
// RIQ_URL is the ReplayIQ adapter. Plain http:// works for local-network hosts
// (*.local, private IPs, 10.0.2.2 from the Android emulator) thanks to the
// patched SDK in third_party/ and the iOS/Android local-network settings, so
// no tunnel is needed when the phone and the Mac share a network. Public hosts
// still need https://. RIQ_PROJECT is sent as the "Mixpanel token"; the
// adapter uses it as the ReplayIQ project id.
import 'package:flutter/material.dart';
import 'package:mixpanel_flutter_session_replay/mixpanel_flutter_session_replay.dart';

const String riqUrl = String.fromEnvironment('RIQ_URL');
const String riqProject = String.fromEnvironment('RIQ_PROJECT', defaultValue: 'demo');

void main() => runApp(const PocApp());

class PocApp extends StatefulWidget {
  const PocApp({super.key});

  @override
  State<PocApp> createState() => _PocAppState();
}

class _PocAppState extends State<PocApp> {
  MixpanelSessionReplay? _replay;
  String _status = 'initializing...';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (riqUrl.isEmpty) {
      setState(() => _status = 'RIQ_URL not set (pass --dart-define=RIQ_URL=https://...)');
      return;
    }
    final result = await MixpanelSessionReplay.initialize(
      token: riqProject,
      distinctId: 'poc_user_1',
      options: SessionReplayOptions(
        serverUrl: riqUrl,
        autoRecordSessionsPercent: 100.0,
        flushInterval: const Duration(seconds: 5),
        logLevel: LogLevel.debug,
        // POC ONLY: text is auto-masked by default, which also blanks the
        // wireframe labels ReplayIQ's AI reads ("tapped button 'Pay now'").
        // Only images stay masked here. Do not do this in a real app.
        // TextFields are visible too, via the patched SDK copy in
        // third_party/ (upstream force-masks every TextField). obscureText
        // fields show as dots and never send their value in the wireframe.
        autoMaskedViews: const {AutoMaskedView.image},
        wireframesOptions: const WireframesOptions(useAccessibilityLabelFallback: true),
        // Emulators often report no Wi-Fi; do not hold uploads back.
        platformOptions: const PlatformOptions(mobile: MobileOptions(wifiOnly: false)),
      ),
    );
    if (!mounted) return;
    setState(() {
      if (result.success) {
        _replay = result.instance;
        _status = 'recording -> $riqUrl';
      } else {
        _status = 'init failed: ${result.errorMessage}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MixpanelSessionReplayWidget(
      instance: _replay,
      child: MaterialApp(
        title: 'ReplayIQ mobile POC',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: CheckoutScreen(status: _status, replay: _replay),
      ),
    );
  }
}

class CheckoutScreen extends StatelessWidget {
  const CheckoutScreen({super.key, required this.status, required this.replay});

  final String status;
  final MixpanelSessionReplay? replay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(status, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          const TextField(decoration: InputDecoration(labelText: 'Full name')),
          const SizedBox(height: 12),
          // Sensitive field: obscureText, so the replay shows dots (••••) like
          // the phone does, and the wireframe never carries its value.
          const TextField(
            obscureText: true,
            decoration: InputDecoration(labelText: 'Card number'),
          ),
          const SizedBox(height: 24),
          // Does nothing on purpose: tap it 3-4 times quickly to produce a rage_click.
          ElevatedButton(onPressed: () {}, child: const Text('Pay now')),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SummaryScreen()),
            ),
            child: const Text('Order summary'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => replay?.flush(),
            child: const Text('Flush now'),
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
          ),
        ),
      ),
    );
  }
}

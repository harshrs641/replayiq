import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'behaviour/errors_console.dart';
import 'behaviour/http_capture.dart';
import 'behaviour/input.dart';
import 'behaviour/navigation.dart';
import 'behaviour/selector.dart';
import 'behaviour/signals.dart';
import 'behaviour/touch.dart';
import 'capture/mask_detector.dart';
import 'capture/screen_capturer.dart';
import 'capture/screen_recorder.dart';
import 'nativedom/assets.dart';
import 'nativedom/dom_recorder.dart';
import 'nativedom/walker.dart';
import 'session/recorder.dart';
import 'session/state_store.dart';
import 'transport/outbox.dart';
import 'transport/uploader.dart';
import 'util/log.dart' as sdk_log;
import 'version.dart';

/// How the screen is recorded.
enum RecordingMode {
  /// Native DOM, falling back to screenshots on screens that are mostly
  /// pixels (maps, camera, games).
  auto,

  /// Native DOM only (Recording API v1.1): the UI as nodes and changes.
  nativeDom,

  /// Screenshots only (Recording API v1).
  screenshot,
}

/// ReplayIQ session replay.
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await ReplayIQ.init(key: 'YOUR_INGEST_KEY', endpoint: 'https://ingest.example.com');
///   runApp(MaterialApp(navigatorObservers: [ReplayIQ.navigatorObserver], ...));
/// }
/// ```
///
/// That records the screen (masked on the device), touches, taps, rage taps,
/// text-field edits, navigation, HTTP requests, errors and `debugPrint`
/// output. Wrap `runApp` in [ReplayIQ.runZoned] to record `print` too.
///
/// Every method is safe to call before [init] finishes or when recording is
/// off; none of them throws.
abstract final class ReplayIQ {
  static _Sdk? _sdk;
  static final List<(String, Map<String, Object?>)> _early = [];
  static bool _initializing = false;

  static final ReplayIQNavigatorObserver _navigator = ReplayIQNavigatorObserver(
    _appEvent,
    () => _sdk?.device.appUrlBase ?? 'app://flutter',
  );

  /// Add to `MaterialApp.navigatorObservers` (or your router's observers)
  /// to record screen changes. Name routes for readable URLs.
  static NavigatorObserver get navigatorObserver => _navigator;

  /// Starts recording.
  ///
  /// - [key]: the project's ingest key (for now, the project id).
  /// - [endpoint]: the ingest host, e.g. `https://ingest.replayiq.example`.
  /// - [sampleRate]: share of sessions recorded, 0-1, decided per session.
  /// - [captureAllHttp]: record every dart:io HTTP request (package:http,
  ///   Dio, `Image.network`) via [HttpOverrides].
  /// - [captureErrors]: record Flutter and uncaught errors.
  /// - [captureConsole]: record `debugPrint` output.
  /// - [recordScreen]: send screenshots and touches. Off sends only events.
  /// - [maskAllText] / [maskAllImages]: paint over all text / images, not
  ///   only text fields and [ReplayIQMask]s.
  /// - [screenshotScale]: image pixels per logical point (1 = 1x).
  /// - [jpegQuality]: 1-100.
  /// - [recordingMode]: native DOM, screenshots, or `auto` (native DOM
  ///   with screenshots for screens that are mostly islands).
  /// - [debug]: print the SDK's own log lines (debug builds only).
  static Future<void> init({
    required String key,
    required String endpoint,
    String? userId,
    Map<String, Object?>? userTraits,
    double sampleRate = 1.0,
    bool captureAllHttp = true,
    bool captureErrors = true,
    bool captureConsole = true,
    bool recordScreen = true,
    bool maskAllText = false,
    bool maskAllImages = false,
    double screenshotScale = 1.0,
    int jpegQuality = 60,
    Duration flushInterval = const Duration(seconds: 5),
    RecordingMode recordingMode = RecordingMode.auto,
    bool debug = false,
    @visibleForTesting Directory? storageDirectory,
    @visibleForTesting http.Client? httpClient,
    @visibleForTesting DeviceInfo? deviceInfo,
  }) async {
    sdk_log.logEnabled = debug;
    if (_sdk != null || _initializing) {
      sdk_log.log('init called again; ignored');
      return;
    }
    _initializing = true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final base = Uri.parse(endpoint.trim());
      if (!base.hasScheme || base.host.isEmpty || key.trim().isEmpty) {
        sdk_log.log('init: a key and an absolute endpoint URL are required');
        return;
      }
      final dir =
          storageDirectory ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/replayiq',
          );
      await dir.create(recursive: true);
      final device = deviceInfo ?? await _deviceInfo();

      // Created before HTTP capture is installed, so uploads use a plain
      // dart:io client and never show up as app traffic.
      final client = httpClient ?? http.Client();
      final outbox = Outbox(Directory('${dir.path}/outbox'));
      await outbox.load();
      final store = StateStore(File('${dir.path}/state.json'));
      await store.load();
      if (userId != null) store.userId = userId;
      if (userTraits != null) {
        store.traits = {
          for (final e in userTraits.entries)
            if (e.value != null) e.key: '${e.value}',
        };
      }

      final ledger = AssetLedger(File('${dir.path}/assets.txt'));
      await ledger.load();
      final processStart = await _processStart();

      late final Recorder recorder;
      final uploader = Uploader(
        outbox: outbox,
        endpoint: base,
        key: key.trim(),
        sdk: sdkName,
        client: client,
        onUnauthorized: () => recorder.onUnauthorized(),
        onAssetStored: (h) => unawaited(ledger.add(h)),
      );
      recorder = Recorder(
        outbox: outbox,
        uploader: uploader,
        store: store,
        device: device,
        sdk: sdkName,
        sampleRate: sampleRate.clamp(0.0, 1.0),
        flushInterval: flushInterval,
        screenSize: _screenSize,
        currentRoute: () => _navigator.currentPath,
        metadataExtras: _metadataExtras,
      );
      final sdk = _Sdk(
        recorder: recorder,
        uploader: uploader,
        device: device,
        base: base,
        maskAllText: maskAllText,
        maskAllImages: maskAllImages,
        recordScreen: recordScreen,
        mode: recordingMode,
        ledger: ledger,
        capturer: ScreenCapturer(
          detector: MaskDetector(
            maskAllText: maskAllText,
            maskAllImages: maskAllImages,
          ),
          scale: screenshotScale.clamp(0.25, 3.0),
          quality: jpegQuality.clamp(1, 100),
        ),
      );
      _sdk = sdk;
      sdk.install(
        captureAllHttp: captureAllHttp,
        captureErrors: captureErrors,
        captureConsole: captureConsole,
      );
      await recorder.start();
      if (processStart != null) {
        unawaited(sdk.signals.appStart('cold', processStart));
      }
      for (final (subtype, fields) in _early) {
        recorder.recordApp(subtype, fields);
      }
      _early.clear();
      sdk_log.log('recording to $base (${device.os}, $sdkName)');
    } catch (e, st) {
      sdk_log.log('init failed: $e\n$st');
    } finally {
      _initializing = false;
    }
  }

  /// Sets the user for this and later sessions.
  static void identify(String userId, {Map<String, Object?>? traits}) =>
      _guard(() => _sdk?.recorder.identify(userId, traits));

  /// Records a named app event (sent as `custom_events`).
  static void track(String name, [Map<String, Object?>? properties]) =>
      _guard(() => _sdk?.recorder.track(name, properties));

  /// A line in the Console tab. [level]: `log`, `warn` or `error`.
  static void log(String message, {String level = 'log'}) =>
      _appEvent('console', {'level': level, 'message': message});

  /// Records a caught error (Console tab, AI analysis).
  static void recordError(Object error, StackTrace? stack) =>
      _guard(() => _sdk?.console.recordError(error, stack));

  /// Stops recording and sending, deletes what is queued, and remembers the
  /// choice across launches until [optIn].
  static Future<void> optOut() async =>
      _guardAsync(() async => await _sdk?.recorder.optOut());

  static Future<void> optIn() async =>
      _guardAsync(() async => await _sdk?.recorder.optIn());

  /// Ends the session (sends it for analysis) and stops recording until
  /// [start] or the next launch.
  static Future<void> stop() async =>
      _guardAsync(() async => await _sdk?.recorder.stop());

  /// Starts a new session after [stop].
  static Future<void> start() async =>
      _guardAsync(() async => await _sdk?.recorder.restart());

  /// Sends buffered events now.
  static Future<void> flush() async =>
      _guardAsync(() async => await _sdk?.recorder.flush());

  /// The session being recorded, if any.
  static String? get sessionId => _sdk?.recorder.session?.id;

  /// Whether this session is being recorded (sampled in, not opted out).
  static bool get isRecording => _sdk?.recorder.isRecording ?? false;

  /// Runs [body] (usually `runApp`) with `print` output recorded as console
  /// logs. Works before [init] completes.
  static R runZoned<R>(R Function() body) => _console.runZoned(body);

  /// A package:http client that records its requests; only needed with
  /// `captureAllHttp: false`.
  static http.Client httpClient([http.Client? inner]) =>
      _sdk?.http.client(inner) ?? inner ?? http.Client();

  // ── internals ──

  static final ErrorConsoleRecorder _console = ErrorConsoleRecorder(_appEvent);

  static void _appEvent(String subtype, Map<String, Object?> fields) {
    _guard(() {
      final sdk = _sdk;
      if (sdk != null) {
        sdk.recorder.recordApp(subtype, fields);
      } else if (_early.length < 200) {
        _early.add((subtype, {...fields, 'timestamp': _nowMs()}));
      }
    });
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static ({int width, int height})? _screenSize() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    final v = views.first;
    final size = v.physicalSize / v.devicePixelRatio;
    return (width: size.width.round(), height: size.height.round());
  }

  static Map<String, Object?> _metadataExtras() {
    final d = WidgetsBinding.instance.platformDispatcher;
    final v = d.views.isEmpty ? null : d.views.first;
    return {
      'locale': d.locale.toLanguageTag(),
      'text_scale': d.textScaleFactor,
      'screen_density': ?v?.devicePixelRatio,
    };
  }

  static Future<DateTime?> _processStart() async {
    try {
      final ms = await const MethodChannel(
        'dev.replayiq.flutter',
      ).invokeMethod<int>('processStartMillis');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Recorder counters for measurement: bytes per request kind, events
  /// per subtype, walk/diff timings and frame stats.
  @visibleForTesting
  static Map<String, Object?>? debugStats() => _sdk?.stats();

  static Future<DeviceInfo> _deviceInfo() async {
    try {
      final m = await const MethodChannel(
        'dev.replayiq.flutter',
      ).invokeMapMethod<String, String>('deviceInfo');
      if (m != null) return DeviceInfo.fromMap(m);
    } catch (_) {}
    return DeviceInfo(
      os: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
    );
  }

  static void _guard(void Function() fn) {
    try {
      fn();
    } catch (e) {
      sdk_log.log('error: $e');
    }
  }

  static Future<void> _guardAsync(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      sdk_log.log('error: $e');
    }
  }

  /// Tears the SDK down so a test can call [init] again.
  @visibleForTesting
  static Future<void> reset() async {
    final sdk = _sdk;
    _sdk = null;
    _early.clear();
    _navigator.currentPath = null;
    await sdk?.dispose();
  }
}

/// The running SDK: the recorder plus the hooks feeding it.
class _Sdk {
  _Sdk({
    required this.recorder,
    required this.uploader,
    required this.device,
    required this.base,
    required this.capturer,
    required this.maskAllText,
    required this.maskAllImages,
    required this.recordScreen,
    required this.mode,
    required this.ledger,
  });

  final Recorder recorder;
  final Uploader uploader;
  final DeviceInfo device;
  final Uri base;
  final ScreenCapturer capturer;
  final bool maskAllText;
  final bool maskAllImages;
  final bool recordScreen;
  final RecordingMode mode;
  final AssetLedger ledger;

  final Map<String, int> eventCounts = {};
  final DateTime started = DateTime.now();

  late final AssetManager assets = AssetManager(
    ledger: ledger,
    upload: recorder.addAsset,
    onChanged: () => dom.request(),
    captureRegions: capturer.captureRegions,
  );
  late final DomRecorder dom = DomRecorder(
    walker: UiWalker(
      assets: assets,
      maskAllText: maskAllText,
      maskAllImages: maskAllImages,
    ),
    assets: assets,
    emit: _record,
    onWalk: _onWalk,
  );
  late final SignalsRecorder signals = SignalsRecorder(
    ReplayIQ._appEvent,
    screen: () => ReplayIQ._navigator.currentPath,
  );

  /// Auto mode: this screen is mostly islands, so screenshots are used
  /// until the route changes.
  bool _fallback = false;

  bool get _domActive =>
      mode == RecordingMode.nativeDom ||
      (mode == RecordingMode.auto && !_fallback);

  void _record(Map<String, Object?> e) {
    final k = '${e['subtype'] ?? e['type']}';
    eventCounts[k] = (eventCounts[k] ?? 0) + 1;
    recorder.record(e);
  }

  void _onWalk(WalkResult result, Size screen) {
    if (mode != RecordingMode.auto || _fallback) return;
    if (result.islandAreaShare(screen) > 0.5) {
      _fallback = true;
      _applyMode();
    }
  }

  void _onScreenChange(String path, {required bool pushed}) {
    if (pushed) signals.routePushed(path);
    dom.markSnapshotNeeded();
    if (_fallback) {
      _fallback = false;
      _applyMode();
    }
  }

  void _applyMode() {
    final on = recorder.capturing.value && recordScreen;
    if (on && _domActive) {
      screen.stop();
      dom.markSnapshotNeeded();
      dom.start();
    } else if (on) {
      dom.stop();
      screen.markKeyframeNeeded();
      screen.start();
    } else {
      dom.stop();
      screen.stop();
    }
  }

  Map<String, Object?> stats() => {
    'mode': mode.name,
    'fallback': _fallback,
    'seconds': DateTime.now().difference(started).inSeconds,
    'bytes': {
      for (final e in recorder.outbox.queuedBytes.entries) e.key.name: e.value,
    },
    'events': Map.of(eventCounts),
    'assets_queued': assets.assetsQueued,
    'dom': dom.stats.toJson(),
    'frames': signals.totals.toJson(),
  };

  late final HttpRecorder http = HttpRecorder(
    ReplayIQ._appEvent,
    isOwnTraffic: _isOwnTraffic,
  );
  ErrorConsoleRecorder get console => ReplayIQ._console;
  late final ScreenRecorder screen = ScreenRecorder(
    capture: capturer.capture,
    emit: _record,
  );
  late final TouchRecorder touch = TouchRecorder(
    emit: (e) {
      if (recordScreen) _record(e);
    },
    app: _appEvent,
    isActive: () => recorder.capturing.value,
    selectorAt: TapSelectorResolver(maskAllText: maskAllText).selectorAt,
  );
  void _appEvent(String subtype, Map<String, Object?> fields) {
    eventCounts[subtype] = (eventCounts[subtype] ?? 0) + 1;
    ReplayIQ._appEvent(subtype, fields);
  }

  late final InputRecorder input = InputRecorder(
    _appEvent,
    isActive: () => recorder.isRecording,
  );
  AppLifecycleListener? _lifecycle;
  bool _backgrounded = false;

  bool _isOwnTraffic(Uri url) {
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    return url.host == base.host &&
        url.port == base.port &&
        url.path.startsWith('$basePath/api/v1/');
  }

  void install({
    required bool captureAllHttp,
    required bool captureErrors,
    required bool captureConsole,
  }) {
    if (captureAllHttp) http.captureAll();
    if (captureErrors) console.installErrorHandlers();
    if (captureConsole) console.installDebugPrint();
    touch.install();
    input.install();
    signals.install();
    ReplayIQ._navigator.onScreenChange = _onScreenChange;
    recorder.capturing.addListener(_onCapturingChanged);
    recorder.sessionId.addListener(_onSession);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null &&
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive) {
      _backgrounded = true;
      recorder.onBackground();
    } else {
      signals.lifecycle('foreground'); // cold: the first one
    }
  }

  void _onCapturingChanged() => _applyMode();

  void _onSession() {
    screen.markKeyframeNeeded();
    dom.markSnapshotNeeded();
  }

  void _onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        screen.markKeyframeNeeded();
        dom.markSnapshotNeeded();
        if (_backgrounded) {
          _backgrounded = false;
          signals.lifecycle('foreground');
          unawaited(signals.appStart('warm', DateTime.now()));
        }
        unawaited(recorder.onForeground());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_backgrounded) {
          _backgrounded = true;
          signals.lifecycle('background');
        }
        unawaited(_background());
      case AppLifecycleState.detached:
        signals.lifecycle('terminate');
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _background() async {
    const channel = MethodChannel('dev.replayiq.flutter');
    input.flush();
    try {
      await channel.invokeMethod<void>('beginBackgroundTask');
    } catch (_) {}
    try {
      recorder.onBackground();
      await recorder.flush();
      await uploader.drain().timeout(const Duration(seconds: 20));
    } catch (_) {
    } finally {
      try {
        await channel.invokeMethod<void>('endBackgroundTask');
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    screen.stop();
    dom.stop();
    signals.uninstall();
    ReplayIQ._navigator.onScreenChange = null;
    touch.uninstall();
    input.uninstall();
    http.release();
    _lifecycle?.dispose();
    recorder.capturing.removeListener(_onCapturingChanged);
    recorder.sessionId.removeListener(_onSession);
    recorder.dispose();
    uploader.stop();
    uploader.close();
  }
}

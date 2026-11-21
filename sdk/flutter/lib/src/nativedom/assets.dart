import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../util/log.dart';
import 'walker.dart';

/// Queues one asset upload (Recording API v1.1 §3).
typedef AssetSink =
    Future<void> Function(String hash, Uint8List bytes, String contentType);

/// Largest asset the API takes.
const int maxAssetBytes = 2 << 20;

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Hashes the server already has, kept on disk so an asset is uploaded
/// once per install.
class AssetLedger {
  AssetLedger(this.file);
  final File? file;
  final Set<String> _stored = {};

  bool contains(String hash) => _stored.contains(hash);

  Future<void> load() async {
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      _stored.addAll((await f.readAsLines()).where((l) => l.length == 64));
    } catch (_) {}
  }

  Future<void> add(String hash) async {
    if (!_stored.add(hash)) return;
    try {
      await file?.writeAsString('$hash\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

/// Encodes images, island crops and fonts into assets and remembers their
/// hashes for the walker.
class AssetManager implements AssetHashes {
  AssetManager({
    required this.ledger,
    required this.upload,
    required this.onChanged,
    this.captureRegions,
    this.islandInterval = const Duration(milliseconds: 500),
    AssetBundle? bundle,
  }) : _bundle = bundle ?? rootBundle;

  final AssetLedger ledger;
  final AssetSink upload;

  /// An asset became available: the recorder re-walks so the node gets it.
  final void Function() onChanged;

  /// Masked JPEG crops of the screen, by island id.
  final Future<Map<int, Uint8List>> Function(Map<int, ui.Rect>)? captureRegions;
  final Duration islandInterval;
  final AssetBundle _bundle;

  final Expando<String> _imageHashes = Expando('replayiq.imageHash');
  final Expando<bool> _encoding = Expando('replayiq.encoding');
  final Map<int, String> _islandHashes = {};
  final Set<String> _queued = {};

  int assetsQueued = 0;

  Future<void> _queue(String hash, Uint8List bytes, String type) async {
    if (bytes.length > maxAssetBytes) {
      log('asset over 2 MB skipped ($type, ${bytes.length} bytes)');
      return;
    }
    if (ledger.contains(hash) || !_queued.add(hash)) return;
    assetsQueued++;
    await upload(hash, bytes, type);
  }

  // ── Images ──

  @override
  String? imageHash(ui.Image image, ui.Size logicalSize) {
    final known = _imageHashes[image];
    if (known != null) return known;
    if (_encoding[image] != true) {
      _encoding[image] = true;
      unawaited(_encodeImage(image, logicalSize));
    }
    return null;
  }

  Future<void> _encodeImage(ui.Image image, ui.Size logical) async {
    try {
      // At most 1x: never upload more pixels than the screen shows.
      final w = logical.width.ceil().clamp(1, image.width);
      final h = logical.height.ceil().clamp(1, image.height);
      ui.Image scaled = image;
      if (w != image.width || h != image.height) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, image.width * 1.0, image.height * 1.0),
          ui.Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        scaled = await picture.toImage(w, h);
        picture.dispose();
      }
      final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
      if (!identical(scaled, image)) scaled.dispose();
      if (data == null) return;
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final hash = sha256Hex(bytes);
      await _queue(hash, bytes, 'image/png');
      _imageHashes[image] = hash;
      onChanged();
    } catch (e) {
      log('image asset failed: $e');
    }
  }

  // ── Islands ──

  @override
  String? islandHash(int nodeId) => _islandHashes[nodeId];

  DateTime? _lastIslands;
  bool _capturing = false;

  /// Captures changed islands, at most every [islandInterval].
  Future<void> captureIslands(List<IslandRef> islands) async {
    final capture = captureRegions;
    final regions = {
      for (final i in islands)
        if (i.capturable && !i.rect.isEmpty) i.id: i.rect,
    };
    if (capture == null || regions.isEmpty || _capturing) return;
    final now = DateTime.now();
    if (_lastIslands != null &&
        now.difference(_lastIslands!) < islandInterval) {
      return;
    }
    _capturing = true;
    _lastIslands = now;
    try {
      final crops = await capture(regions);
      var changed = false;
      for (final e in crops.entries) {
        final hash = sha256Hex(e.value);
        if (_islandHashes[e.key] == hash) continue;
        await _queue(hash, e.value, 'image/jpeg');
        _islandHashes[e.key] = hash;
        changed = true;
      }
      if (changed) onChanged();
    } catch (e) {
      log('island capture failed: $e');
    } finally {
      _capturing = false;
    }
  }

  // ── Fonts ──

  Map<String, List<(String asset, int weight)>>? _manifest;
  final Map<String, List<Map<String, Object?>>> _fonts = {};
  final Set<String> _fontsPending = {};

  /// `fonts` entries for a snapshot: bundled families seen so far.
  List<Map<String, Object?>> fontsFor(Set<String> families) {
    final out = <Map<String, Object?>>[];
    for (final f in families) {
      final known = _fonts[f];
      if (known != null) {
        out.addAll(known);
      } else if (_fontsPending.add(f)) {
        unawaited(_loadFont(f));
      }
    }
    return out;
  }

  Future<void> _loadFont(String family) async {
    try {
      _manifest ??= await _readManifest();
      final files = _manifest![family];
      if (files == null) {
        _fonts[family] = const []; // a system font: nothing to upload
        return;
      }
      final entries = <Map<String, Object?>>[];
      for (final (asset, weight) in files) {
        final data = await _bundle.load(asset);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final hash = sha256Hex(bytes);
        final type = asset.toLowerCase().endsWith('.otf')
            ? 'font/otf'
            : 'font/ttf';
        await _queue(hash, bytes, type);
        if (bytes.length <= maxAssetBytes) {
          entries.add({'family': family, 'w': weight, 'a': hash});
        }
      }
      _fonts[family] = entries;
      if (entries.isNotEmpty) onChanged();
    } catch (e) {
      _fonts[family] = const [];
      log('font $family not uploaded: $e');
    }
  }

  Future<Map<String, List<(String, int)>>> _readManifest() async {
    final json = jsonDecode(await _bundle.loadString('FontManifest.json'));
    final out = <String, List<(String, int)>>{};
    for (final f in (json as List).cast<Map<String, dynamic>>()) {
      final family = f['family'] as String;
      out[family] = [
        for (final font in (f['fonts'] as List).cast<Map<String, dynamic>>())
          (font['asset'] as String, (font['weight'] as num?)?.toInt() ?? 400),
      ];
      // Packaged fonts are referenced as `packages/<pkg>/<family>`; Flutter
      // also resolves the bare family for the app's own fonts.
    }
    return out;
  }

  /// True once a font family's assets were looked up (done or system).
  bool fontsResolved(Set<String> families) =>
      families.every(_fonts.containsKey);
}

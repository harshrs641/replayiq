// Screenshot capture of the whole Flutter view, masked before encoding.
//
// Derived from mixpanel_flutter_session_replay 2.1.0 (ScreenshotCapturer,
// ToImageFrameAcquirer, MaskPainter, NativeImageCompressor), Copyright 2022
// Mixpanel, Inc., Apache-2.0; see LICENSE and NOTICE.
//
// Changes from upstream: captures the root RenderView's layer, so the app
// needs no wrapper widget; masks are painted at the output scale; the output
// scale and JPEG quality are configurable; web, wireframes and replay
// identity pinning removed.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../util/log.dart';
import 'mask_detector.dart';

/// Encodes opaque RGBA pixels as JPEG; null on failure.
typedef JpegEncoder =
    Future<Uint8List?> Function(
      Uint8List rgba,
      int width,
      int height,
      int quality,
    );

/// The platform JPEG encoder (UIImage / Bitmap.compress), off the UI thread.
Future<Uint8List?> nativeJpegEncoder(
  Uint8List rgba,
  int width,
  int height,
  int quality,
) async {
  try {
    return await _channel.invokeMethod<Uint8List>('compressJpeg', {
      'rgba': rgba,
      'width': width,
      'height': height,
      'quality': quality,
    });
  } catch (e) {
    log('JPEG encoding failed: $e');
    return null;
  }
}

const _channel = MethodChannel('dev.replayiq.flutter');

/// One masked, encoded screenshot.
class CapturedFrame {
  const CapturedFrame({
    required this.jpeg,
    required this.logicalSize,
    required this.capturedAt,
    required this.maskCount,
  });

  final Uint8List jpeg;

  /// Screen size in logical points.
  final Size logicalSize;
  final DateTime capturedAt;
  final int maskCount;
}

sealed class CaptureOutcome {
  const CaptureOutcome();
}

final class CaptureOk extends CaptureOutcome {
  const CaptureOk(this.frame);
  final CapturedFrame frame;
}

/// Not captured now (route transition, nothing laid out yet); try again.
final class CaptureRetry extends CaptureOutcome {
  const CaptureRetry(this.reason);
  final String reason;
}

/// Capture failed (encoder or engine error).
final class CaptureFailed extends CaptureOutcome {
  const CaptureFailed(this.reason);
  final String reason;
}

class ScreenCapturer {
  ScreenCapturer({
    required this.detector,
    this.encode = nativeJpegEncoder,
    this.scale = 1.0,
    this.quality = 60,
  });

  final MaskDetector detector;
  final JpegEncoder encode;

  /// Output pixels per logical point.
  final double scale;

  /// JPEG quality, 1-100.
  final int quality;

  final _maskPaint = Paint()
    ..color = const Color(0xFFB0B0B0)
    ..style = PaintingStyle.fill;

  Future<CaptureOutcome> capture() async {
    final frame = await _maskedFrame();
    if (frame is! _Masked) return frame as CaptureOutcome;
    final masked = frame.image;
    try {
      final bytes = await masked.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return const CaptureFailed('no pixels');
      final jpeg = await encode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        masked.width,
        masked.height,
        quality,
      );
      if (jpeg == null) return const CaptureFailed('encode failed');
      return CaptureOk(
        CapturedFrame(
          jpeg: jpeg,
          logicalSize: frame.size,
          capturedAt: frame.at,
          maskCount: frame.maskCount,
        ),
      );
    } catch (e) {
      return CaptureFailed('$e');
    } finally {
      masked.dispose();
    }
  }

  /// JPEGs of [regions] (logical, screen coordinates) cut from one masked
  /// capture of the screen, keyed like [regions]. Empty when the screen
  /// can't be captured now. Used for native-DOM raster islands.
  Future<Map<int, Uint8List>> captureRegions(Map<int, Rect> regions) async {
    final out = <int, Uint8List>{};
    if (regions.isEmpty) return out;
    final frame = await _maskedFrame();
    if (frame is! _Masked) return out;
    final image = frame.image;
    try {
      for (final e in regions.entries) {
        final r = e.value.intersect(Offset.zero & frame.size);
        if (r.isEmpty) continue;
        final w = (r.width * scale).ceil(), h = (r.height * scale).ceil();
        if (w <= 0 || h <= 0) continue;
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(
          image,
          Rect.fromLTWH(r.left * scale, r.top * scale, w * 1.0, h * 1.0),
          Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
          Paint(),
        );
        final picture = recorder.endRecording();
        final crop = await picture.toImage(w, h);
        picture.dispose();
        try {
          final bytes = await crop.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (bytes == null) continue;
          final jpeg = await encode(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            w,
            h,
            quality,
          );
          if (jpeg != null) out[e.key] = jpeg;
        } finally {
          crop.dispose();
        }
      }
    } finally {
      image.dispose();
    }
    return out;
  }

  /// The whole screen at [scale], masks painted, or why not.
  Future<Object> _maskedFrame() async {
    final scheduler = SchedulerBinding.instance;
    // The mask walk and the snapshot must see the same painted frame.
    if (scheduler.schedulerPhase != SchedulerPhase.idle ||
        scheduler.hasScheduledFrame) {
      await scheduler.endOfFrame;
    }

    final binding = WidgetsBinding.instance;
    final views = binding.renderViews;
    if (views.isEmpty) return const CaptureRetry('no render view');
    final view = views.first;
    final root = view.child;
    final rootElement = binding.rootElement;
    if (root == null || !root.hasSize || rootElement == null) {
      return const CaptureRetry('not laid out');
    }
    // The RenderView's own layer holds the whole scene (it is the root of
    // the layer tree). It is protected only to keep render objects from
    // poking at each other's layers; reading it to rasterize is what
    // RenderRepaintBoundary.toImage does for a sub-tree.
    // ignore: invalid_use_of_protected_member
    final layer = view.layer;
    if (layer is! OffsetLayer || !layer.attached) {
      return const CaptureRetry('no layer');
    }

    final MaskDetectionResult masks;
    try {
      masks = detector.detect(root, rootElement);
    } catch (e) {
      return CaptureFailed('$e');
    }
    if (masks.shouldSkipCapture) {
      return const CaptureRetry('transition in progress');
    }

    // No await between the mask walk and toImage: the scene is built from
    // the layer tree synchronously here.
    final size = root.size;
    final dpr = view.flutterView.devicePixelRatio;
    final capturedAt = DateTime.now();
    final Future<ui.Image> rawFuture;
    try {
      rawFuture = layer.toImage(
        Rect.fromLTWH(0, 0, size.width * dpr, size.height * dpr),
        pixelRatio: scale / dpr,
      );
    } catch (e) {
      return CaptureFailed('toImage: $e');
    }
    ui.Image? raw;
    try {
      raw = await rawFuture;
      final masked = await _paintMasks(raw, masks.regions);
      return _Masked(masked, size, capturedAt, masks.regions.length);
    } catch (e) {
      return CaptureFailed('$e');
    } finally {
      raw?.dispose();
    }
  }

  Future<ui.Image> _paintMasks(ui.Image image, List<MaskRegion> regions) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    canvas.drawImage(image, Offset.zero, Paint());
    for (final r in regions) {
      final b = r.bounds;
      canvas.drawRect(
        Rect.fromLTRB(
          b.left * scale,
          b.top * scale,
          b.right * scale,
          b.bottom * scale,
        ),
        _maskPaint,
      );
    }
    final picture = recorder.endRecording();
    return picture
        .toImage(image.width, image.height)
        .whenComplete(picture.dispose);
  }
}

class _Masked {
  _Masked(this.image, this.size, this.at, this.maskCount);
  final ui.Image image;
  final Size size;
  final DateTime at;
  final int maskCount;
}

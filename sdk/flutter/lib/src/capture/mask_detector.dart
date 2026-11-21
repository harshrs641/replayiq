// Derived from mixpanel_flutter_session_replay 2.1.0
// (lib/src/internal/masking/mask_detector.dart), Copyright 2022 Mixpanel, Inc.,
// licensed under the Apache License 2.0; see LICENSE and NOTICE.
//
// Changes from upstream: works on any root RenderBox (ReplayIQ captures the
// whole view, not a RepaintBoundary), MixpanelMask/MixpanelUnmask became
// ReplayIQMask/ReplayIQUnmask, wireframe collection removed, and editable
// text is always masked (security), even inside ReplayIQUnmask.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../widgets/mask.dart';

/// Why a region is painted over.
enum MaskSource {
  /// Auto-masked text or image (`maskAllText` / `maskAllImages`).
  auto,

  /// Inside a [ReplayIQMask].
  manual,

  /// A text input (always masked).
  security,
}

/// A rectangle painted over before the screenshot is encoded, in logical
/// points relative to the captured root.
class MaskRegion {
  const MaskRegion(this.bounds, this.source);

  final Rect bounds;
  final MaskSource source;

  @override
  bool operator ==(Object other) =>
      other is MaskRegion && bounds == other.bounds && source == other.source;

  @override
  int get hashCode => Object.hash(bounds, source);

  @override
  String toString() => 'MaskRegion($bounds, $source)';
}

/// What the mask walk found.
class MaskDetectionResult {
  const MaskDetectionResult(this.regions, {this.shouldSkipCapture = false});

  final List<MaskRegion> regions;

  /// True during route transitions and overscroll stretch, where the painted
  /// pixels and the render tree's geometry disagree, so masks could miss.
  final bool shouldSkipCapture;
}

enum _MaskContext { none, mask, unmask }

/// Walks the element tree and returns the regions to paint over.
class MaskDetector {
  MaskDetector({this.maskAllText = false, this.maskAllImages = false});

  /// Mask every `Text` / `RichText` (not only inputs).
  final bool maskAllText;

  /// Mask every image.
  final bool maskAllImages;

  static final Map<Type, String> _typeNames = {};
  static final Map<Type, bool> _scrollableTypes = {};
  static final Map<Type, bool> _viewportTypes = {};

  MaskDetectionResult detect(RenderBox root, Element rootElement) {
    final regions = <MaskRegion>[];
    final state = _State();
    try {
      _visit(
        rootElement,
        root,
        regions,
        state,
        context: _MaskContext.none,
        viewport: null,
      );
    } catch (e) {
      throw MaskDetectionException('Widget tree traversal failed: $e');
    }
    return MaskDetectionResult(
      regions,
      shouldSkipCapture: state.shouldSkipCapture,
    );
  }

  void _visit(
    Element element,
    RenderBox root,
    List<MaskRegion> regions,
    _State state, {
    required _MaskContext context,
    required Rect? viewport,
  }) {
    final widget = element.widget;

    if (_hasUnsafeVisualState(widget)) state.shouldSkipCapture = true;

    // Background Navigator routes are wrapped in TickerMode(enabled: false).
    if (widget is TickerMode && !widget.enabled) return;
    if (widget is Visibility && !widget.visible) return;
    if (widget is Opacity && widget.opacity < 0.001) return;

    // Cache the enclosing scrollable's bounds, so items scrolled out of view
    // are not masked (they are not painted either).
    var currentViewport = viewport;
    if (currentViewport == null) {
      final ro = element.renderObject;
      if ((_isScrollable(widget) || _isViewport(ro)) &&
          ro is RenderBox &&
          ro.hasSize) {
        try {
          final offset =
              ro.localToGlobal(Offset.zero) - root.localToGlobal(Offset.zero);
          currentViewport = offset & ro.size;
        } catch (_) {}
      }
    }

    var currentContext = context;
    if (widget is ReplayIQMask) {
      _addElement(element, root, regions, MaskSource.manual);
      currentContext = _MaskContext.mask;
    } else if (widget is ReplayIQUnmask) {
      currentContext = _MaskContext.unmask;
    } else {
      final ro = element.renderObject;
      if (element is RenderObjectElement && ro is RenderEditable) {
        // Inputs are always masked, whatever the context.
        final r = _visibleBounds(ro, root, currentViewport);
        if (r != null) regions.add(MaskRegion(r, MaskSource.security));
      } else {
        switch (currentContext) {
          case _MaskContext.mask:
            _addElement(element, root, regions, MaskSource.manual);
          case _MaskContext.unmask:
            break;
          case _MaskContext.none:
            if (element is RenderObjectElement &&
                ((maskAllText && ro is RenderParagraph) ||
                    (maskAllImages && ro is RenderImage))) {
              final r = _visibleBounds(ro as RenderBox, root, currentViewport);
              if (r != null) regions.add(MaskRegion(r, MaskSource.auto));
            }
        }
      }
    }

    // Skips Offstage, hidden Overlay entries and inactive IndexedStack
    // children.
    element.debugVisitOnstageChildren((child) {
      _visit(
        child,
        root,
        regions,
        state,
        context: currentContext,
        viewport: currentViewport,
      );
    });
  }

  bool _hasUnsafeVisualState(Widget widget) {
    final type = widget.runtimeType;
    final name = _typeNames.putIfAbsent(type, type.toString);
    if (name == '_ModalScopeStatus') {
      try {
        final route = (widget as dynamic).route;
        if (route is ModalRoute) {
          bool moving(AnimationStatus? s) =>
              s == AnimationStatus.forward || s == AnimationStatus.reverse;
          return moving(route.animation?.status) ||
              moving(route.secondaryAnimation?.status);
        }
      } catch (_) {}
      return false;
    }
    if (name == 'StretchEffect') {
      try {
        return (widget as dynamic).stretchStrength != 0.0;
      } catch (_) {}
    }
    return false;
  }

  void _addElement(
    Element element,
    RenderBox root,
    List<MaskRegion> regions,
    MaskSource source,
  ) {
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.hasSize) return;
    try {
      final offset =
          ro.localToGlobal(Offset.zero) - root.localToGlobal(Offset.zero);
      final rootRect = Offset.zero & root.size;
      final bounds = offset & ro.size;
      if (!rootRect.overlaps(bounds)) return;
      regions.add(MaskRegion(bounds.intersect(rootRect), source));
    } catch (_) {}
  }

  /// Painted bounds of [node] relative to [root], clipped to the root and the
  /// enclosing viewport; null when nothing of it is visible.
  Rect? _visibleBounds(RenderBox node, RenderBox root, Rect? viewport) {
    if (!node.hasSize || !node.attached || node.paintBounds.isEmpty) {
      return null;
    }
    try {
      final bounds = MatrixUtils.transformRect(
        node.getTransformTo(root),
        node.paintBounds,
      );
      final rootRect = Offset.zero & root.size;
      if (!rootRect.overlaps(bounds)) return null;
      var clipped = bounds.intersect(rootRect);
      if (viewport != null) {
        if (!viewport.overlaps(clipped)) return null;
        clipped = clipped.intersect(viewport);
      }
      if (clipped.width <= 0 || clipped.height <= 0) return null;
      return clipped;
    } catch (_) {
      return null;
    }
  }

  bool _isScrollable(Widget widget) {
    if (widget is ScrollView ||
        widget is SingleChildScrollView ||
        widget is PageView ||
        widget is NestedScrollView) {
      return true;
    }
    return _scrollableTypes.putIfAbsent(widget.runtimeType, () {
      final n = widget.runtimeType.toString();
      return n.contains('ScrollView') ||
          n.contains('ListView') ||
          n.contains('GridView') ||
          n.contains('PageView') ||
          n.contains('TableView');
    });
  }

  bool _isViewport(RenderObject? ro) {
    if (ro == null) return false;
    if (ro is RenderViewport || ro is RenderShrinkWrappingViewport) return true;
    return _viewportTypes.putIfAbsent(
      ro.runtimeType,
      () => ro.runtimeType.toString().contains('RenderViewport'),
    );
  }
}

class _State {
  bool shouldSkipCapture = false;
}

class MaskDetectionException implements Exception {
  MaskDetectionException(this.message);
  final String message;

  @override
  String toString() => 'MaskDetectionException: $message';
}

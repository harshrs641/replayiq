// Turns Flutter's render tree into the native DOM of Recording API v1.1.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart'
    show InputBorder, OutlineInputBorder, UnderlineInputBorder;
import 'package:flutter/rendering.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

import '../widgets/mask.dart';
import 'node.dart';

/// Supplies asset hashes for images and islands. Returns null while an
/// asset is still being encoded; the walker then sends the node without
/// `a` and the recorder re-walks when it is ready.
abstract class AssetHashes {
  String? imageHash(ui.Image image, Size logicalSize);
  String? islandHash(int nodeId);
}

/// An island found by a walk, for rasterizing.
class IslandRef {
  IslandRef(this.id, this.rect, {required this.capturable});
  final int id;

  /// In root (screen) coordinates.
  final Rect rect;

  /// False for platform views, which Flutter can't rasterize.
  final bool capturable;
}

class WalkResult {
  WalkResult(this.root, this.islands, this.families, this.nodeCount);
  final UiNode root;
  final List<IslandRef> islands;

  /// Font families used by text nodes.
  final Set<String> families;
  final int nodeCount;

  double islandAreaShare(Size screen) {
    if (screen.isEmpty) return 0;
    var area = 0.0;
    for (final i in islands) {
      final r = i.rect.intersect(Offset.zero & screen);
      if (!r.isEmpty) area += r.width * r.height;
    }
    return area / (screen.width * screen.height);
  }
}

/// Debug aid: types turned into islands.
final List<String> debugIslandTypes = [];

class UiWalker {
  UiWalker({
    required this.assets,
    this.maskAllText = false,
    this.maskAllImages = false,
  });

  final AssetHashes assets;
  final bool maskAllText;
  final bool maskAllImages;

  // Stable ids for a render object's lifetime; never reused.
  final Expando<int> _ids = Expando('replayiq.ids');
  final Expando<int> _lineIds = Expando('replayiq.lineIds');
  int _nextId = 2; // 1 is the root
  static final Map<Type, String> _names = {};

  late List<IslandRef> _islands;
  late Set<String> _families;
  late int _count;
  late RenderBox _root;

  int idOf(RenderObject ro) => _ids[ro] ??= _nextId++;

  WalkResult walk(RenderBox root) {
    _islands = [];
    _families = {};
    _count = 1;
    _root = root;
    final size = root.size;
    final node = UiNode(1, 'view', [0, 0, r1(size.width), r1(size.height)]);
    _visit(root, node, Matrix4.identity(), unmasked: false);
    return WalkResult(node, _islands, _families, _count);
  }

  String _name(Object o) => _names.putIfAbsent(o.runtimeType, () {
    return o.runtimeType.toString().split('<').first;
  });

  /// Visits [ro]'s painted children. [m] maps [ro]'s coordinates to
  /// [parent]'s.
  void _children(
    RenderObject ro,
    UiNode parent,
    Matrix4 m, {
    required bool unmasked,
  }) {
    void visit(RenderObject child) {
      final cm = m.clone();
      try {
        ro.applyPaintTransform(child, cm);
      } catch (_) {
        return; // not laid out
      }
      _visit(child, parent, cm, unmasked: unmasked);
    }

    final name = _name(ro);
    if (ro is RenderIndexedStack || name == '_RenderTheater') {
      // Only the displayed child / onstage routes.
      ro.visitChildrenForSemantics(visit);
    } else {
      ro.visitChildren(visit);
    }
  }

  void _visit(
    RenderObject ro,
    UiNode parent,
    Matrix4 m, {
    required bool unmasked,
  }) {
    if (ro is RenderOffstage && ro.offstage) return;
    if (ro is RenderBox) {
      if (!ro.hasSize) return;
    } else if (ro is! RenderSliver) {
      return;
    }

    if (ro is RenderReplayIQMaskMarker) {
      if (ro.mask) {
        _emit(ro, parent, m, 'mask');
        return;
      }
      _children(ro, parent, m, unmasked: true);
      return;
    }
    if (ro is RenderEditable) {
      _emit(ro, parent, m, 'input')
        ..role = 'input'
        ..input = {
          'type': ro.obscureText ? 'password' : 'text',
          'focus': ro.hasFocus,
        };
      return; // the value is never read
    }
    if (ro is RenderParagraph) {
      if (maskAllText && !unmasked) {
        _emit(ro, parent, m, 'mask');
      } else {
        _emit(ro, parent, m, 'text').tx = _text(ro);
      }
      return;
    }
    if (ro is RenderImage) {
      final image = ro.image;
      if (maskAllImages && !unmasked) {
        _emit(ro, parent, m, 'mask');
      } else {
        final node = _emit(ro, parent, m, 'image');
        final hash = image == null ? null : assets.imageHash(image, ro.size);
        node.img = {'a': ?hash, 'fit': _fit(ro.fit)};
      }
      return;
    }
    if (ro is RenderViewportBase) {
      final px = ro.offset.hasPixels ? ro.offset.pixels : 0.0;
      _scroll(ro, parent, m, ro.axisDirection, px, unmasked);
      return;
    }
    final name = _name(ro);
    if (name == '_RenderSingleChildViewport') {
      try {
        final d = ro as dynamic;
        final ViewportOffset offset = d.offset;
        _scroll(
          ro,
          parent,
          m,
          d.axisDirection as AxisDirection,
          offset.hasPixels ? offset.pixels : 0.0,
          unmasked,
        );
        return;
      } catch (_) {}
    }
    if (ro is RenderUiKitView ||
        ro is RenderAndroidView ||
        ro is PlatformViewRenderBox) {
      _island(ro as RenderBox, parent, m, capturable: false);
      return;
    }
    if (ro is RenderCustomPaint) {
      final painters = [ro.painter, ro.foregroundPainter].nonNulls;
      if (painters.isNotEmpty) {
        final known = painters.every(_ignoredPainter);
        final border = painters
            .map(_inputBorder)
            .whereType<Map<String, Object?>>()
            .firstOrNull;
        if (border != null) {
          final node = _emit(ro, parent, m, 'view');
          _inputBorderNodes(ro, node, border);
          _children(ro, node, Matrix4.identity(), unmasked: unmasked);
          return;
        }
        final shape = painters
            .where((p) => p.runtimeType.toString() == '_ShapeBorderPainter')
            .firstOrNull;
        if (shape != null) {
          // Material's outline for shaped widgets: a bordered view.
          Map<String, Object?> style = const {};
          try {
            style = _shape((shape as dynamic).border as ShapeBorder, ro.size);
          } catch (_) {}
          if (style.isEmpty) {
            _children(ro, parent, m, unmasked: unmasked);
          } else {
            final node = _emit(ro, parent, m, 'view')
              ..s = {...?_t(ro, m), ...style};
            _children(ro, node, Matrix4.identity(), unmasked: unmasked);
          }
          return;
        }
        if (!known) {
          _island(ro, parent, m, capturable: true);
          return;
        }
      }
    }

    final style = _boxStyle(ro, name);
    if (style != null && style.isNotEmpty) {
      final node = _emit(ro, parent, m, 'view')..s = {...?_t(ro, m), ...style};
      _children(ro, node, Matrix4.identity(), unmasked: unmasked);
      return;
    }

    // Unknown leaf that paints itself (e.g. a custom RenderBox): pixels.
    if (ro is RenderBox && _isUnknownPainterLeaf(ro)) {
      _island(ro, parent, m, capturable: true);
      return;
    }
    _children(ro, parent, m, unmasked: unmasked);
  }

  void _scroll(
    RenderObject ro,
    UiNode parent,
    Matrix4 m,
    AxisDirection dir,
    double px,
    bool unmasked,
  ) {
    final vertical = axisDirectionToAxis(dir) == Axis.vertical;
    final node = _emit(ro, parent, m, 'scroll')
      ..s = {...?_t(ro, m), 'clip': true}
      ..so = vertical ? [0, r1(px)] : [r1(px), 0];
    // Children in content coordinates: undo the scroll offset that the
    // viewport's paint transform applies, so scrolling changes only `so`.
    final reversed = axisDirectionIsReversed(dir);
    final shift = reversed ? -px : px;
    final content = vertical
        ? Matrix4.translationValues(0, shift, 0)
        : Matrix4.translationValues(shift, 0, 0);
    _children(ro, node, content, unmasked: unmasked);
  }

  void _island(
    RenderBox ro,
    UiNode parent,
    Matrix4 m, {
    required bool capturable,
  }) {
    final node = _emit(ro, parent, m, 'island');
    assert(() {
      debugIslandTypes.add(
        '${ro.runtimeType} ${ro is RenderCustomPaint ? '${ro.painter?.runtimeType}/${ro.foregroundPainter?.runtimeType}' : ''}',
      );
      return true;
    }());
    final hash = capturable ? assets.islandHash(node.id) : null;
    node.img = {'a': ?hash, 'fit': 'fill'};
    try {
      final rect = MatrixUtils.transformRect(
        ro.getTransformTo(_root),
        Offset.zero & ro.size,
      );
      _islands.add(IslandRef(node.id, rect, capturable: capturable));
    } catch (_) {}
  }

  /// Adds a node for [ro] under [parent]. [m] maps [ro] to [parent].
  UiNode _emit(RenderObject ro, UiNode parent, Matrix4 m, String kind) {
    final size = ro is RenderBox ? ro.size : Size.zero;
    final node = UiNode(idOf(ro), kind, const []);
    _placeNode(node, m, size);
    parent.c.add(node);
    _count++;
    return node;
  }

  /// The transform part of a just-emitted node's style, if any.
  Map<String, Object?>? _t(RenderObject ro, Matrix4 m) {
    final s = m.storage;
    if (s[0] == 1 && s[1] == 0 && s[4] == 0 && s[5] == 1) return null;
    return {
      't': [_r3(s[0]), _r3(s[1]), _r3(s[4]), _r3(s[5]), 0, 0],
    };
  }

  /// Frame plus, when [m] is not a pure translation, a transform about the
  /// node's centre (spec: `s.t`).
  void _placeNode(UiNode node, Matrix4 m, Size size) {
    final s = m.storage;
    final a = s[0], b = s[1], c = s[4], d = s[5];
    final w = size.width, h = size.height;
    if (a == 1 && b == 0 && c == 0 && d == 1) {
      node.f = [r1(s[12]), r1(s[13]), r1(w), r1(h)];
      return;
    }
    final centre = m.transform3(Vector3(w / 2, h / 2, 0));
    node.f = [r1(centre.x - w / 2), r1(centre.y - h / 2), r1(w), r1(h)];
    (node.s ??= {})['t'] = [_r3(a), _r3(b), _r3(c), _r3(d), 0, 0];
  }

  // Styles of render objects that paint a box.
  Map<String, Object?>? _boxStyle(RenderObject ro, String name) {
    if (ro is RenderDecoratedBox) {
      final d = ro.decoration;
      if (d is BoxDecoration) {
        final size = ro.size;
        return {
          'bg': ?_color(d.color),
          ..._radius(d.borderRadius, d.shape, size),
          ..._border(d.border),
          'sh': ?_shadow(d.boxShadow),
          'grad': ?_gradient(d.gradient),
        };
      }
      if (d is ShapeDecoration) {
        return {
          'bg': ?_color(d.color),
          ..._shape(d.shape, ro.size),
          'sh': ?_shadow(d.shadows),
          'grad': ?_gradient(d.gradient),
        };
      }
      return null;
    }
    if (ro is RenderPhysicalModel) {
      return {
        'bg': ?_color(ro.color),
        ..._radius(ro.borderRadius, ro.shape, ro.size),
        'sh': ?_elevation(ro.elevation, ro.shadowColor),
        if (ro.clipBehavior != Clip.none) 'clip': true,
      };
    }
    if (ro is RenderPhysicalShape) {
      final clipper = ro.clipper;
      return {
        'bg': ?_color(ro.color),
        if (clipper is ShapeBorderClipper) ..._shape(clipper.shape, ro.size),
        'sh': ?_elevation(ro.elevation, ro.shadowColor),
        if (ro.clipBehavior != Clip.none) 'clip': true,
      };
    }
    if (name == '_RenderColoredBox') {
      try {
        return {'bg': ?_color((ro as dynamic).color as Color)};
      } catch (_) {
        return null;
      }
    }
    if (ro is RenderClipRRect && ro.clipBehavior != Clip.none) {
      final r = ro.borderRadius;
      return {'clip': true, if (r is BorderRadius) 'r': _radii(r)};
    }
    if ((ro is RenderClipRect && ro.clipBehavior != Clip.none) ||
        (ro is RenderClipPath && ro.clipBehavior != Clip.none)) {
      return {'clip': true};
    }
    if (ro is RenderClipOval && ro.clipBehavior != Clip.none) {
      final s = (ro as RenderBox).size;
      final r = r1(math.min(s.width, s.height) / 2);
      return {
        'clip': true,
        'r': [r, r, r, r],
      };
    }
    final double? o = switch (ro) {
      RenderOpacity() => ro.opacity,
      RenderAnimatedOpacity() => ro.opacity.value,
      RenderSliverOpacity() => ro.opacity,
      RenderSliverAnimatedOpacity() => ro.opacity.value,
      _ => null,
    };
    // Fully opaque wrappers add nothing (most of the tree has a few).
    if (o != null && o < 0.999) return {'o': _r3(o)};
    return null;
  }

  static bool _isUnknownPainterLeaf(RenderBox ro) {
    if (ro.size.isEmpty) return false;
    if (ro is RenderProxyBox || ro is RenderShiftedBox) return false;
    var hasChild = false;
    ro.visitChildren((_) => hasChild = true);
    return !hasChild;
  }

  // Painters drawn by Flutter itself that the replay doesn't need.
  static bool _ignoredPainter(CustomPainter p) {
    final n = p.runtimeType.toString();
    return n.contains('Scrollbar') ||
        n == 'BannerPainter' ||
        n.contains('OverscrollIndicator') ||
        n.contains('Glow') ||
        n == '_InputBorderPainter';
  }

  /// A TextField's border, from Material's private painter.
  static Map<String, Object?>? _inputBorder(CustomPainter p) {
    if (p.runtimeType.toString() != '_InputBorderPainter') return null;
    try {
      final d = p as dynamic;
      final InputBorder border = d.border.evaluate(d.borderAnimation);
      final Color? fill = d.fillColor as Color?;
      return {'border': border, 'fill': fill};
    } catch (_) {
      return const {};
    }
  }

  void _inputBorderNodes(
    RenderCustomPaint ro,
    UiNode node,
    Map<String, Object?> info,
  ) {
    final border = info['border'];
    final fill = info['fill'] as Color?;
    final size = ro.size;
    final style = <String, Object?>{
      if (fill != null && fill.a > 0) 'bg': hexColor(fill),
    };
    if (border is OutlineInputBorder &&
        border.borderSide.style != BorderStyle.none) {
      style['bw'] = r1(border.borderSide.width);
      style['bc'] = hexColor(border.borderSide.color);
      style['r'] = _radii(border.borderRadius);
    }
    final merged = {...?node.s, ...style};
    node.s = merged.isEmpty ? null : merged;
    if (border is UnderlineInputBorder &&
        border.borderSide.style != BorderStyle.none) {
      // The underline: a thin view along the bottom edge.
      final w = border.borderSide.width;
      final line = UiNode(_lineIds[ro] ??= _nextId++, 'view', [
        0,
        r1(size.height - w),
        r1(size.width),
        r1(w),
      ])..s = {'bg': hexColor(border.borderSide.color)};
      node.c.add(line);
      _count++;
    }
  }

  Map<String, Object?> _text(RenderParagraph ro) {
    final leaves = <(String, TextStyle?)>[];
    void collect(InlineSpan span, TextStyle? inherited) {
      final style = inherited == null
          ? span.style
          : (span.style == null ? inherited : inherited.merge(span.style));
      if (span is TextSpan) {
        final t = span.text;
        if (t != null && t.isNotEmpty) leaves.add((t, style));
        for (final child in span.children ?? const <InlineSpan>[]) {
          collect(child, style);
        }
      }
    }

    collect(ro.text, null);
    final scaler = ro.textScaler;
    Map<String, Object?> styleOf(TextStyle? s) {
      if (s == null) return const {};
      final size = s.fontSize == null ? null : scaler.scale(s.fontSize!);
      if (s.fontFamily != null) _families.add(s.fontFamily!);
      return {
        'font': ?s.fontFamily,
        'size': ?(size == null ? null : r1(size)),
        'w': ?s.fontWeight?.value,
        if (s.fontStyle == FontStyle.italic) 'i': true,
        'col': ?_color(s.color ?? s.foreground?.color),
        'lh': ?((size != null && s.height != null)
            ? r1(size * s.height!)
            : null),
      };
    }

    final first = leaves.isEmpty ? null : leaves.first.$2;
    return {
      if (leaves.length <= 1)
        'v': leaves.isEmpty ? '' : leaves.first.$1
      else
        'spans': [
          for (final (v, s) in leaves) {'v': v, ...styleOf(s)},
        ],
      ...styleOf(first),
      'al': _align(ro.textAlign, ro.textDirection),
      'ml': ?ro.maxLines,
    };
  }

  static String _align(TextAlign a, TextDirection dir) => switch (a) {
    TextAlign.left => 'left',
    TextAlign.right => 'right',
    TextAlign.center => 'center',
    TextAlign.justify => 'justify',
    TextAlign.start => dir == TextDirection.ltr ? 'left' : 'right',
    TextAlign.end => dir == TextDirection.ltr ? 'right' : 'left',
  };

  static String _fit(BoxFit? fit) => switch (fit) {
    BoxFit.cover => 'cover',
    BoxFit.contain ||
    BoxFit.scaleDown ||
    BoxFit.fitWidth ||
    BoxFit.fitHeight => 'contain',
    BoxFit.none => 'none',
    _ => 'fill',
  };

  static String? _color(Color? c) =>
      (c == null || c.a == 0) ? null : hexColor(c);

  static double _r3(double v) => (v * 1000).roundToDouble() / 1000;

  static List<double> _radii(BorderRadius r) => [
    r1(r.topLeft.x),
    r1(r.topRight.x),
    r1(r.bottomRight.x),
    r1(r.bottomLeft.x),
  ];

  static Map<String, Object?> _radius(
    BorderRadiusGeometry? r,
    BoxShape shape,
    Size size,
  ) {
    if (shape == BoxShape.circle) {
      final v = r1(math.min(size.width, size.height) / 2);
      return {
        'r': [v, v, v, v],
      };
    }
    if (r is BorderRadius && r != BorderRadius.zero) return {'r': _radii(r)};
    if (r != null && r != BorderRadius.zero) {
      return {'r': _radii(r.resolve(TextDirection.ltr))};
    }
    return const {};
  }

  static Map<String, Object?> _border(BoxBorder? b) {
    if (b is Border && b.isUniform && b.top.style != BorderStyle.none) {
      return {'bw': r1(b.top.width), 'bc': hexColor(b.top.color)};
    }
    return const {};
  }

  static Map<String, Object?> _shape(ShapeBorder shape, Size size) {
    final out = <String, Object?>{};
    BorderSide? side;
    if (shape is RoundedRectangleBorder) {
      out.addAll(_radius(shape.borderRadius, BoxShape.rectangle, size));
      side = shape.side;
    } else if (shape is StadiumBorder) {
      final v = r1(math.min(size.width, size.height) / 2);
      out['r'] = [v, v, v, v];
      side = shape.side;
    } else if (shape is CircleBorder) {
      out.addAll(_radius(null, BoxShape.circle, size));
      side = shape.side;
    } else if (shape is ContinuousRectangleBorder) {
      out.addAll(_radius(shape.borderRadius, BoxShape.rectangle, size));
      side = shape.side;
    }
    if (side != null && side.style != BorderStyle.none && side.width > 0) {
      out['bw'] = r1(side.width);
      out['bc'] = hexColor(side.color);
    }
    return out;
  }

  static List<Object>? _shadow(List<BoxShadow>? shadows) {
    final s = shadows?.firstOrNull;
    if (s == null) return null;
    return [
      r1(s.offset.dx),
      r1(s.offset.dy),
      r1(s.blurRadius),
      r1(s.spreadRadius),
      hexColor(s.color),
    ];
  }

  static List<Object>? _elevation(double e, Color shadow) {
    if (e <= 0) return null;
    // Roughly Material's key shadow.
    return [0, r1(e / 2), r1(e), 0, hexColor(shadow.withValues(alpha: 0.25))];
  }

  static Map<String, Object?>? _gradient(Gradient? g) {
    if (g is LinearGradient) {
      final b = g.begin.resolve(TextDirection.ltr);
      final e = g.end.resolve(TextDirection.ltr);
      final angle =
          (math.atan2(e.y - b.y, e.x - b.x) * 180 / math.pi + 90) % 360;
      return {'type': 'linear', 'angle': r1(angle), 'stops': _stops(g)};
    }
    if (g is RadialGradient) return {'type': 'radial', 'stops': _stops(g)};
    return null;
  }

  static List<List<Object>> _stops(Gradient g) => [
    for (var i = 0; i < g.colors.length; i++)
      [
        hexColor(g.colors[i]),
        g.stops != null && i < g.stops!.length
            ? _r3(g.stops![i])
            : (g.colors.length == 1 ? 0 : _r3(i / (g.colors.length - 1))),
      ],
  ];
}

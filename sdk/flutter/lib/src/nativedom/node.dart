import 'dart:ui' show Color;

/// One node of the native DOM (Recording API v1.1 §1).
class UiNode {
  UiNode(this.id, this.k, this.f);

  final int id;

  /// view, text, image, input, island, scroll, mask.
  String k;

  /// [x, y, w, h] relative to the parent's content box.
  List<double> f;
  Map<String, Object?>? s;
  String? role;
  String? label;
  Map<String, Object?>? tx;
  Map<String, Object?>? img;
  Map<String, Object?>? input;
  List<double>? so;
  final List<UiNode> c = [];

  /// Everything but the children: what an update carries.
  Map<String, Object?> own() => {
    'id': id,
    'k': k,
    'f': f,
    's': ?s,
    'role': ?role,
    'label': ?label,
    'tx': ?tx,
    'img': ?img,
    'in': ?input,
    'so': ?so,
  };

  Map<String, Object?> toJson() => {
    ...own(),
    if (c.isNotEmpty) 'c': [for (final n in c) n.toJson()],
  };

  /// Visits this node and its subtree, parents first.
  void visit(void Function(UiNode node, UiNode? parent) f, [UiNode? parent]) {
    f(this, parent);
    for (final child in c) {
      child.visit(f, this);
    }
  }
}

/// `#AARRGGBB`.
String hexColor(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Rounds to 0.1 pt so sub-pixel jitter doesn't produce updates.
double r1(double v) => v.isFinite ? (v * 10).roundToDouble() / 10 : 0;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../widgets/mask.dart';

/// Names the widget under a tap: `role:"label"` (`button:"Pay now"`,
/// `input:"Card number"`, `listitem:"Item 3"`), or just the role when it
/// has no readable label or is masked.
class TapSelectorResolver {
  TapSelectorResolver({this.maskAllText = false});

  /// When text is masked in the replay, labels are not sent either.
  final bool maskAllText;

  static const int _maxLabel = 60;

  /// Resolves the selector for a tap at [position] (logical, global).
  String? selectorAt(Offset position) {
    final binding = WidgetsBinding.instance;
    final views = binding.renderViews;
    if (views.isEmpty) return null;
    final result = HitTestResult();
    binding.hitTestInView(result, position, views.first.flutterView.viewId);
    final hits = <RenderObject>[
      for (final e in result.path)
        if (e.target is RenderObject) e.target as RenderObject,
    ];
    if (hits.isEmpty) return null;
    final root = binding.rootElement;
    if (root == null) return null;
    final elements = _elementsFor(root, hits.toSet());
    for (final ro in hits) {
      final element = elements[ro];
      if (element != null) return describe(element);
    }
    return null;
  }

  /// The RenderObjectElements owning [wanted], found in one walk.
  Map<RenderObject, Element> _elementsFor(
    Element root,
    Set<RenderObject> wanted,
  ) {
    final found = <RenderObject, Element>{};
    void visit(Element e) {
      if (found.length == wanted.length) return;
      if (e is RenderObjectElement && wanted.contains(e.renderObject)) {
        found[e.renderObject] = e;
      }
      e.visitChildElements(visit);
    }

    visit(root);
    return found;
  }

  /// Selector for the deepest element hit by a tap.
  @visibleForTesting
  String describe(Element hit) {
    Element? weak, strong;
    String? strongRole;
    var sinceWeak = 0, depth = 0;
    var masked = false, unmasked = false;
    String? ancestorTooltip;

    bool check(Element e) {
      final w = e.widget;
      if (w is ReplayIQMask) masked = true;
      if (w is ReplayIQUnmask && !masked) unmasked = true;
      // An icon button's Tooltip wraps the InkWell the tap lands in.
      if (w is Tooltip && depth < 150) ancestorTooltip ??= w.message;
      depth++;
      if (strong == null) {
        final role = strongRoleOf(w);
        if (role != null && (weak == null || sinceWeak <= 30)) {
          strong = e;
          strongRole = role;
        } else if (weak == null && _isWeakTappable(w)) {
          weak = e;
        } else if (weak != null) {
          sinceWeak++;
        }
      }
      return true; // keep walking: a ReplayIQMask anywhere above masks it
    }

    check(hit);
    hit.visitAncestorElements(check);

    final target = strong ?? weak;
    final role =
        strongRole ?? (weak != null ? 'button' : _leafRole(hit.renderObject));
    if (target == null || masked) return role;

    String? label;
    if (role == 'input') {
      label = _inputLabel(target);
    } else {
      label =
          _textLabel(target, hideText: maskAllText && !unmasked) ??
          ancestorTooltip;
    }
    if (label == null || label.isEmpty) return role;
    return '$role:"${_clean(label)}"';
  }

  /// Widgets with a specific role. Matched by type, nearest first.
  @visibleForTesting
  static String? strongRoleOf(Widget w) {
    if (w is TextField || w is CupertinoTextField || w is EditableText) {
      return 'input';
    }
    if (w is CheckboxListTile || w is Checkbox || w is CupertinoCheckbox) {
      return 'checkbox';
    }
    if (w is SwitchListTile || w is Switch || w is CupertinoSwitch) {
      return 'switch';
    }
    if (w is RadioListTile || w is Radio) return 'radio';
    if (w is Slider || w is CupertinoSlider) return 'slider';
    if (w is ListTile || w is CupertinoListTile) return 'listitem';
    if (w is Tab) return 'tab';
    if (w is Chip || w is ActionChip || w is FilterChip || w is ChoiceChip) {
      return 'button';
    }
    final name = w.runtimeType.toString();
    final base = name.split('<').first;
    if (!base.startsWith('_') && base.endsWith('Button')) return 'button';
    return null;
  }

  static bool _isWeakTappable(Widget w) =>
      (w is InkWell && w.onTap != null) ||
      (w is InkResponse && w.onTap != null) ||
      (w is GestureDetector && w.onTap != null);

  static String _leafRole(RenderObject? ro) {
    if (ro is RenderParagraph) return 'text';
    if (ro is RenderImage) return 'image';
    return 'view';
  }

  String? _inputLabel(Element field) {
    final w = field.widget;
    if (w is TextField) {
      return w.decoration?.labelText ??
          w.decoration?.hintText ??
          w.decoration?.semanticCounterText;
    }
    if (w is CupertinoTextField) return w.placeholder;
    // EditableText hit directly: look for the TextField above it.
    String? label;
    field.visitAncestorElements((e) {
      final a = e.widget;
      if (a is TextField) {
        label = a.decoration?.labelText ?? a.decoration?.hintText;
        return false;
      }
      if (a is CupertinoTextField) {
        label = a.placeholder;
        return false;
      }
      return true;
    });
    return label;
  }

  /// Visible text under [target] (never text-field contents), else its
  /// tooltip / icon / semantics label.
  String? _textLabel(Element target, {required bool hideText}) {
    final texts = <String>[];
    String? accessible;
    var masked = false;

    void visit(Element e) {
      final w = e.widget;
      if (w is ReplayIQMask) {
        masked = true;
        return;
      }
      if (w is EditableText) return;
      if (w is Icon) {
        accessible ??= w.semanticLabel;
        return; // its glyph is not readable text
      }
      if (w is Tooltip) accessible ??= w.message;
      if (w is Semantics) accessible ??= w.properties.label;
      final ro = e.renderObject;
      if (!hideText && e is RenderObjectElement && ro is RenderParagraph) {
        final t = ro.text
            .toPlainText(
              includeSemanticsLabels: false,
              includePlaceholders: false,
            )
            .trim();
        if (t.isNotEmpty && !_isIconGlyph(t)) texts.add(t);
      }
      e.visitChildElements(visit);
    }

    final w = target.widget;
    if (w is IconButton) accessible = w.tooltip;
    visit(target);
    if (masked) return null;
    final text = texts.join(' ');
    if (text.isNotEmpty) return text;
    final a = accessible?.trim();
    return (a == null || a.isEmpty) ? null : a;
  }

  static bool _isIconGlyph(String t) =>
      t.runes.every((r) => r >= 0xE000 && r <= 0xF8FF);

  static String _clean(String label) {
    var s = label.replaceAll('"', "'").replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > _maxLabel) s = '${s.substring(0, _maxLabel - 1)}…';
    return s;
  }
}

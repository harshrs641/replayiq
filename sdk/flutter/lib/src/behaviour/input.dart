import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'navigation.dart' show AppEventSink;

/// Emits `input` (`selector: input:"<label>"`) when a text field loses focus
/// after being edited. The value is never read beyond "did it change".
class InputRecorder {
  InputRecorder(this._sink, {required this.isActive});

  final AppEventSink _sink;
  final bool Function() isActive;

  EditableTextState? _field;
  int? _initialHash;
  String? _label;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addListener(_onFocusChange);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FocusManager.instance.removeListener(_onFocusChange);
  }

  void _onFocusChange() {
    try {
      final focused = FocusManager.instance.primaryFocus?.context;
      final field = focused?.findAncestorStateOfType<EditableTextState>();
      if (identical(field, _field)) return;
      _finish();
      if (field != null && field.mounted) {
        _field = field;
        _initialHash = field.textEditingValue.text.hashCode;
        _label = labelFor(field.context);
        if (isActive()) _sink('focus', {'selector': _selector(_label)});
      }
    } catch (_) {}
  }

  /// Ends tracking of the focused field (also on app background).
  void flush() => _finish();

  void _finish() {
    final f = _field;
    _field = null;
    if (f == null || !isActive()) return;
    final selector = _selector(_label);
    if (f.mounted && f.textEditingValue.text.hashCode != _initialHash) {
      _sink('input', {'selector': selector});
    }
    _sink('blur', {'selector': selector});
  }

  static String _selector(String? label) => label == null || label.isEmpty
      ? 'input'
      : 'input:"${label.replaceAll('"', "'")}"';

  /// The field's label or hint, never its value.
  static String? labelFor(BuildContext context) {
    final tf = context.findAncestorWidgetOfExactType<TextField>();
    if (tf != null) {
      return tf.decoration?.labelText ?? tf.decoration?.hintText;
    }
    return context
        .findAncestorWidgetOfExactType<CupertinoTextField>()
        ?.placeholder;
  }
}

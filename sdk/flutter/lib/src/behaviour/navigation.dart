import 'package:flutter/widgets.dart';

typedef AppEventSink =
    void Function(String subtype, Map<String, Object?> fields);

/// Records screen changes as `navigate` events with
/// `url: app://<bundle id>/<route name>`. Name routes
/// (`RouteSettings(name: '/checkout')`) for readable URLs.
class ReplayIQNavigatorObserver extends NavigatorObserver {
  ReplayIQNavigatorObserver(this._sink, this._appUrlBase);

  final AppEventSink _sink;
  final String Function() _appUrlBase;

  /// Path of the screen showing (`checkout`, or `''` for the home route).
  String? currentPath;

  /// Called when the screen changes; [pushed] for a new route.
  void Function(String path, {required bool pushed})? onScreenChange;

  void _record(Route<dynamic>? route, {bool pushed = false}) {
    if (route == null || route is PopupRoute) return; // dialogs, menus
    final name = route.settings.name;
    final path = routePath(name);
    // A rebuilt Navigator re-pushes the screen already showing.
    if (path == currentPath) return;
    currentPath = path;
    _sink('navigate', {
      'url': '${_appUrlBase()}/$path',
      'message': name ?? route.runtimeType.toString(),
    });
    onScreenChange?.call(path, pushed: pushed);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record(route, pushed: true);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _record(newRoute);
}

/// `'/order-summary'` -> `'order-summary'`; the home route is `''`.
String routePath(String? name) {
  if (name == null || name.isEmpty || name == '/') return '';
  return name.replaceFirst(RegExp(r'^/+'), '');
}

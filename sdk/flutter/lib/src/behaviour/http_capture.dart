// HTTP capture.
import 'dart:io';

import 'package:http/http.dart' as http;

import 'navigation.dart' show AppEventSink;

/// Records one `network` event per HTTP request: method, URL, status and
/// duration (status 0 plus `error` when no response arrived). Never request
/// or response bodies or headers.
class HttpRecorder {
  HttpRecorder(this._sink, {required this.isOwnTraffic});

  final AppEventSink _sink;

  /// ReplayIQ's own uploads, which are not recorded.
  final bool Function(Uri url) isOwnTraffic;

  bool capturingAll = false;
  HttpOverrides? _previous;

  /// Records every request made through dart:io's HttpClient: package:http,
  /// Dio, `Image.network` and most other HTTP libraries use it. Wraps any
  /// [HttpOverrides] already installed.
  void captureAll() {
    if (capturingAll) return;
    capturingAll = true;
    _previous = HttpOverrides.current;
    HttpOverrides.global = RecordingHttpOverrides(this, _previous);
  }

  /// Puts back the overrides that were installed before [captureAll].
  void release() {
    if (!capturingAll) return;
    capturingAll = false;
    HttpOverrides.global = _previous;
  }

  /// A package:http client that records its requests. Not needed with
  /// [captureAll], which already sees them.
  http.Client client([http.Client? inner]) =>
      RecordingClient(inner ?? http.Client(), this);

  void recordRequest(
    String method,
    Uri url,
    Stopwatch watch, {
    int status = 0,
    Object? error,
  }) {
    if (isOwnTraffic(url)) return;
    _sink('network', {
      'method': method,
      'url': url.toString(),
      'status': status,
      'duration': watch.elapsedMilliseconds,
      if (error != null) 'error': error.toString(),
    });
  }
}

class RecordingClient extends http.BaseClient {
  RecordingClient(this._inner, this._companion);
  final http.Client _inner;
  final HttpRecorder _companion;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // captureAllHttp records it already, at the dart:io level.
    if (_companion.capturingAll) return _inner.send(request);
    final watch = Stopwatch()..start();
    try {
      final res = await _inner.send(request);
      _companion.recordRequest(
        request.method,
        request.url,
        watch,
        status: res.statusCode,
      );
      return res;
    } catch (e) {
      _companion.recordRequest(request.method, request.url, watch, error: e);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

class RecordingHttpOverrides extends HttpOverrides {
  RecordingHttpOverrides(this._companion, this._previous);
  final HttpRecorder _companion;
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _RecordingHttpClient(
    _previous?.createHttpClient(context) ?? super.createHttpClient(context),
    _companion,
  );

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// Forwards everything to a real HttpClient and records each request once
/// its response headers arrive (HttpClientRequest.done), or when it fails.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this._inner, this._companion);
  final HttpClient _inner;
  final HttpRecorder _companion;

  Future<HttpClientRequest> _track(
    String method,
    Uri url,
    Future<HttpClientRequest> opening,
  ) async {
    final watch = Stopwatch()..start();
    final HttpClientRequest req;
    try {
      req = await opening;
    } catch (e) {
      _companion.recordRequest(
        method,
        url,
        watch,
        error: e,
      ); // e.g. DNS, refused
      rethrow;
    }
    req.done.then(
      (res) => _companion.recordRequest(
        req.method,
        req.uri,
        watch,
        status: res.statusCode,
      ),
      onError: (Object e) =>
          _companion.recordRequest(req.method, req.uri, watch, error: e),
    );
    return req;
  }

  Uri _uri(String host, int port, String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _track(method, url, _inner.openUrl(method, url));
  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _track(
    method,
    _uri(host, port, path),
    _inner.open(method, host, port, path),
  );
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

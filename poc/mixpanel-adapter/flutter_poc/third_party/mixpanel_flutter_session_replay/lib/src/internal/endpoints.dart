import '../models/data_residency.dart';

/// Builds the full `/record` and `/settings` endpoint URLs from a base server
/// URL.
///
/// Mirrors the Android implementation: any path on the base URL is preserved,
/// only a trailing `/` is trimmed before appending the endpoint path. This
/// allows custom base URLs such as `https://proxy.example.com/mp` to resolve
/// to `https://proxy.example.com/mp/record`.
abstract final class EndPoints {
  /// Default base URL used when no override is provided.
  static const String defaultBaseUrl = DataResidency.us;

  /// Build the `/record` endpoint URL for the given base URL.
  static String record(String baseUrl) =>
      '${_trimTrailingSlash(baseUrl)}/record';

  /// Build the `/settings` endpoint URL for the given base URL.
  static String settings(String baseUrl) =>
      '${_trimTrailingSlash(baseUrl)}/settings';

  static String _trimTrailingSlash(String input) {
    var end = input.length;
    while (end > 0 && input.codeUnitAt(end - 1) == 0x2F /* '/' */ ) {
      end--;
    }
    return input.substring(0, end);
  }
}

/// Result of validating a [SessionReplayOptions.serverUrl] value.
///
/// Mirrors Android's `Result<String>` returned from `validateServerUrl`.
sealed class ServerUrlValidation {
  const ServerUrlValidation();
}

/// Validation succeeded; [trimmedUrl] is the canonical value to use.
final class ServerUrlValid extends ServerUrlValidation {
  final String trimmedUrl;
  const ServerUrlValid(this.trimmedUrl);
}

/// Validation failed; [message] explains why.
final class ServerUrlInvalid extends ServerUrlValidation {
  final String message;
  const ServerUrlInvalid(this.message);
}

/// Validate a user-supplied `serverUrl` value.
///
/// Mirrors Android's `SessionReplayManager.validateServerUrl`:
/// - whitespace is trimmed
/// - URL must start with `https://`
/// - URL must parse as a valid absolute URI with a host
///
/// Notably this does NOT reject URLs that include a path — proxy URLs like
/// `https://proxy.example.com/mp` are accepted, and the path is preserved
/// when building the record/settings endpoints. (The iOS implementation
/// rejects such URLs; we intentionally diverge from iOS to match Android.)
///
/// REPLAYIQ POC PATCH: `http://` is also accepted when the host is on the
/// local network (see [isLocalNetworkHost]), so the app can post straight to
/// a self-hosted collector on the same Wi-Fi without a public HTTPS tunnel.
/// Public hosts still require `https://`.
ServerUrlValidation validateServerUrl(String url) {
  final trimmed = url.trim();

  final parsed = Uri.tryParse(trimmed);
  final isHttps = trimmed.startsWith('https://');
  final isLocalHttp =
      trimmed.startsWith('http://') &&
      parsed != null &&
      isLocalNetworkHost(parsed.host);
  if (!isHttps && !isLocalHttp) {
    return ServerUrlInvalid(
      'serverUrl must start with https:// (http:// is only allowed for '
      'local-network hosts), got: "$trimmed"',
    );
  }

  if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
    return ServerUrlInvalid('serverUrl "$trimmed" is malformed');
  }

  return ServerUrlValid(trimmed);
}

/// REPLAYIQ POC PATCH: hosts that never leave the local network: localhost,
/// mDNS `*.local` names, private/loopback/link-local IPv4 (incl. the Android
/// emulator's 10.0.2.2) and loopback/link-local/unique-local IPv6.
bool isLocalNetworkHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local')) return true;

  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(h);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!);
    final b = int.parse(v4.group(2)!);
    return a == 10 ||
        a == 127 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254);
  }

  // Uri.host strips the [] around IPv6 literals.
  if (h.contains(':')) {
    return h == '::1' ||
        h.startsWith('fe8') ||
        h.startsWith('fe9') ||
        h.startsWith('fea') ||
        h.startsWith('feb') ||
        h.startsWith('fc') ||
        h.startsWith('fd');
  }
  return false;
}

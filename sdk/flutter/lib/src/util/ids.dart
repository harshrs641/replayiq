import 'dart:math';

final Random _random = Random.secure();

/// A random (version 4) UUID.
String uuidV4([Random? random]) {
  final r = random ?? _random;
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// UTC ISO-8601 with millisecond precision, as the API expects.
String isoUtc(DateTime t) => t.toUtc().toIso8601String();

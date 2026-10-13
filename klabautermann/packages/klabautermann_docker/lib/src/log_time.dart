import 'package:meta/meta.dart';

/// 03 §5.6: a log or event timestamp with nanosecond resolution. The
/// Engine API's `since=` parameter takes Unix seconds and a 9-digit
/// nanosecond fraction (`1234567890.123456789`); it rejects RFC3339 with
/// a 400, so the conversion lives here and the raw text is never sent.
@immutable
final class LogTimestamp implements Comparable<LogTimestamp> {
  const LogTimestamp(this.seconds, this.nanos)
    : assert(nanos >= 0 && nanos < 1000000000, 'nanos out of range');

  final int seconds;
  final int nanos;

  /// From the daemon's Unix `time` seconds plus optional `timeNano`.
  factory LogTimestamp.fromUnix(int seconds, {int nanos = 0}) =>
      LogTimestamp(seconds, nanos.clamp(0, 999999999));

  /// The `since=`/`until=` query value: seconds and 9-digit nanos.
  String get sinceQuery => '$seconds.${nanos.toString().padLeft(9, '0')}';

  /// A UTC [DateTime] for display; sub-microsecond digits are truncated.
  DateTime toDateTime() => DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000 + nanos ~/ 1000000,
    isUtc: true,
  );

  @override
  int compareTo(LogTimestamp other) {
    if (seconds != other.seconds) return seconds - other.seconds;
    return nanos - other.nanos;
  }

  bool operator <(LogTimestamp o) => compareTo(o) < 0;
  bool operator <=(LogTimestamp o) => compareTo(o) <= 0;
  bool operator >(LogTimestamp o) => compareTo(o) > 0;
  bool operator >=(LogTimestamp o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) =>
      other is LogTimestamp && seconds == other.seconds && nanos == other.nanos;

  @override
  int get hashCode => Object.hash(seconds, nanos);

  @override
  String toString() => sinceQuery;

  /// Parses an RFC3339/RFC3339Nano timestamp (03 §5.6), keeping the full
  /// nanosecond fraction. Returns null on anything else.
  static LogTimestamp? tryParse(String? text) {
    if (text == null) return null;
    final m = _rfc3339.firstMatch(text.trim());
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);
    final frac = m.group(7) ?? '';
    final zone = m.group(8)!;

    final base = DateTime.utc(year, month, day, hour, minute, second);
    var epochSeconds = base.millisecondsSinceEpoch ~/ 1000;
    if (zone != 'Z' && zone != 'z') {
      final sign = zone[0] == '-' ? -1 : 1;
      final oh = int.parse(zone.substring(1, 3));
      final om = int.parse(zone.substring(4, 6));
      epochSeconds -= sign * (oh * 3600 + om * 60);
    }
    final nanos = _fractionToNanos(frac);
    return LogTimestamp(epochSeconds, nanos);
  }

  static int _fractionToNanos(String frac) {
    if (frac.isEmpty) return 0;
    final digits = frac.length >= 9 ? frac.substring(0, 9) : frac;
    return int.parse(digits.padRight(9, '0'));
  }
}

final RegExp _rfc3339 = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})'
  r'(?:\.(\d+))?([Zz]|[+-]\d{2}:\d{2})$',
);

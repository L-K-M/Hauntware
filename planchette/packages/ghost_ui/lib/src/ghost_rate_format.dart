import 'package:flutter/foundation.dart' show TargetPlatform;

import 'ghost_file_format.dart';

/// Presentation formatting for transfer rates and ETAs (Poltergeist 02
/// §5.3/§6's rendering rules) plus the IEC binary sizes Klabautermann's
/// server views need. The literals here are technical (unit glyphs, the
/// `/s` suffix, the parse grammar); all user-facing strings stay
/// caller-supplied so each host's localization contract is untouched.
///
/// `ghostFormatByteRate`, `ghostFormatCompactEta` and
/// `ghostParseByteRate` moved verbatim from Poltergeist's
/// `lib/ui/activity/activity_format.dart` (`formatTransferRate`/
/// `formatTransferLimit`, `formatTransferEta`, `parseTransferRate`); the
/// parse ceiling stays a caller parameter so each host keeps its own
/// input policy.
const _binaryUnits = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];

/// IEC binary size — divisor 1024 with KiB/MiB/GiB/TiB unit names on
/// every platform, the convention server tooling reports in. Unlike
/// [ghostFormatFileSize] this never switches to a decimal divisor; like
/// it, a missing size renders the shared unevaluated dash.
String ghostFormatBinarySize(int? bytes) {
  if (bytes == null) return ghostUnevaluated;
  const divisor = 1024.0;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= divisor && unit < _binaryUnits.length - 1) {
    value /= divisor;
    unit++;
  }
  if (unit == 0) return '$bytes ${_binaryUnits[0]}';
  // Round numerically first so renormalization never depends on parsing
  // the formatted text (a later locale-aware formatter must not be able
  // to break the loop on comma decimals).
  double rounded() =>
      value >= 10 ? value.roundToDouble() : (value * 10).roundToDouble() / 10;
  var text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  // Rounding can push the mantissa back up to the divisor (1023.99 KiB
  // rounds to "1024 KiB"); renormalize so a boundary value renders as
  // the next unit, like Finder/Explorer.
  while (rounded() >= divisor && unit < _binaryUnits.length - 1) {
    unit++;
    value /= divisor;
    text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  }
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_binaryUnits[unit]}';
}

/// A rate in IEC binary units — [ghostFormatBinarySize] plus the `/s`
/// suffix, Klabautermann's convention on every platform.
String ghostFormatBinaryRate(num bytesPerSecond) =>
    '${ghostFormatBinarySize(bytesPerSecond.round())}/s';

/// A transfer rate as "2.3 MB/s" — the platform file managers' size
/// convention ([ghostFormatFileSize]) plus the `/s` suffix, so an app
/// whose listing renders decimal sizes reads the same rate. The `/s`
/// suffix is machine grammar, not copy.
String ghostFormatByteRate(
  num bytesPerSecond, {
  required TargetPlatform platform,
}) => '${ghostFormatFileSize(bytesPerSecond.round(), platform: platform)}/s';

/// ETA text (02 §5.3): compact, one-decimal-free, capped at days —
/// "45s", "4m 20s", "1h 3m", "2d 5h". The unit glyphs are technical
/// formatting.
String ghostFormatCompactEta(Duration eta) {
  var seconds = eta.inSeconds;
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ${seconds % 60}s';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h ${minutes % 60}m';
  return '${hours ~/ 24}d ${hours % 24}h';
}

/// A custom rate field's grammar (02 §6): a number optionally followed
/// by a byte unit (B, KB, MB, GB, TB — decimal like
/// [ghostFormatFileSize]) and an optional `/s`. A bare number means
/// bytes per second. Returns bytes/sec, or null on anything the grammar
/// does not cover or that exceeds [maxBytesPerSecond] — the field
/// renders that as an inline error and never clamps. The ceiling is
/// caller policy, not embedded here.
int? ghostParseByteRate(String input, {required int maxBytesPerSecond}) {
  final match = _ratePattern.firstMatch(input.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (value == null || value <= 0) return null;
  final unit = match.group(2)?.toLowerCase();
  final multiplier = switch (unit) {
    null || '' || 'b' => 1,
    'k' || 'kb' => 1000,
    'm' || 'mb' => 1000 * 1000,
    'g' || 'gb' => 1000 * 1000 * 1000,
    't' || 'tb' => 1000 * 1000 * 1000 * 1000,
    _ => -1,
  };
  if (multiplier < 0) return null;
  // Reject before rounding: an over-range literal saturates the
  // product to Infinity, and Infinity.round() throws — an invalid
  // entry must surface the inline error, never crash or clamp.
  final product = value * multiplier;
  if (!product.isFinite || product > maxBytesPerSecond) {
    return null;
  }
  final bytes = product.round();
  if (bytes <= 0) return null;
  return bytes;
}

final _ratePattern = RegExp(
  r'^(\d+(?:[.,]\d+)?)\s*([kmgt]?i?b)?(?:\s*/\s*s)?$',
  caseSensitive: false,
);

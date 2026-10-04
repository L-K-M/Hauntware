import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:intl/intl.dart';

/// Presentation formatting for file-listing rows (Poltergeist 02 §2.3's
/// rendering rules, foundation subset). The literals here are technical
/// (units, the unevaluated dash); all user-facing strings — the
/// today/yesterday labels and the locale name — stay caller-supplied so
/// each host's localization contract is untouched.
///
/// Ported verbatim from Poltergeist's `lib/ui/panes/pane_format.dart`
/// (`formatPaneSize`, `formatPaneModified`, `formatPosixModeSymbolic`,
/// `formatPosixModeOctal`) and `lib/services/pane_permissions.dart`
/// (`nameIsFlagged`), renamed into the `ghost` vocabulary over the
/// neutral [GhostFileItem] model.
const _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB'];
const _unevaluated = '—';

/// The shared "no value" glyph (02 §2.3's unevaluated dash) for surfaces
/// beyond the row formatter — an inspector renders absent metadata with
/// the same dash the listing uses.
const ghostUnevaluated = _unevaluated;

/// Decimal size for macOS/Linux, binary for Windows — the platform file
/// managers' convention (02 §2.3).
String ghostFormatFileSize(int? bytes, {required TargetPlatform platform}) {
  if (bytes == null) return _unevaluated;
  final divisor = platform == TargetPlatform.windows ? 1024.0 : 1000.0;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= divisor && unit < _byteUnits.length - 1) {
    value /= divisor;
    unit++;
  }
  if (unit == 0) return '$bytes ${_byteUnits[0]}';
  // Round numerically first so renormalization never depends on parsing
  // the formatted text (a later locale-aware formatter must not be able
  // to break the loop on comma decimals).
  double rounded() =>
      value >= 10 ? value.roundToDouble() : (value * 10).roundToDouble() / 10;
  var text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  // Rounding can push the mantissa back up to the divisor (999.999 KB
  // rounds to "1000 KB"); renormalize so a boundary value renders as
  // the next unit, like Finder/Explorer.
  while (rounded() >= divisor && unit < _byteUnits.length - 1) {
    unit++;
    value /= divisor;
    text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  }
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_byteUnits[unit]}';
}

// Retain only the current locale's parsed patterns across row builds.
// Explicit locales keep these independent of Intl.defaultLocale.
_GhostFileDateFormats? _cachedDateFormats;

_GhostFileDateFormats _dateFormatsFor(String localeName) {
  final cached = _cachedDateFormats;
  if (cached != null && cached.localeName == localeName) return cached;
  return _cachedDateFormats = _GhostFileDateFormats(localeName);
}

class _GhostFileDateFormats {
  _GhostFileDateFormats(this.localeName);

  final String localeName;
  late final time = DateFormat.jm(localeName);
  late final dateTime = DateFormat.yMd(localeName).add_jm();
}

/// Modified-time text: relative for today/yesterday, absolute otherwise
/// (02 §2.3). Links and unevaluated sizes carry null metadata — the
/// dash. [today] and [yesterday] are the host's localized labels (each
/// takes the formatted time), [now] is the host's clock, and
/// [localeName] the locale intl formats in — nothing app-specific is
/// embedded here.
String ghostFormatFileModified(
  DateTime? modified, {
  required DateTime now,
  required String localeName,
  required String Function(String time) today,
  required String Function(String time) yesterday,
}) {
  if (modified == null) return _unevaluated;
  final localModified = modified.toLocal();
  final localNow = now.toLocal();
  final dayStart = DateTime(localNow.year, localNow.month, localNow.day);
  final formats = _dateFormatsFor(localeName);
  final time = formats.time.format(localModified);
  if (!localModified.isBefore(dayStart)) {
    // Same calendar day → "today"; genuinely future mtimes (clock skew,
    // migrated archives) fall through to the absolute format rather
    // than reading as today.
    final nextDayStart = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 1,
    );
    return localModified.isBefore(nextDayStart)
        ? today(time)
        : formats.dateTime.format(localModified);
  }
  // Calendar-day arithmetic, not 24-hour subtraction: across a DST
  // transition, midnight minus 24h lands at 23:00 or 01:00 of the
  // previous day (Dart normalizes out-of-range day components).
  if (!localModified.isBefore(
    DateTime(localNow.year, localNow.month, localNow.day - 1),
  )) {
    return yesterday(time);
  }
  return formats.dateTime.format(localModified);
}

/// The `ls -l` symbolic rendering of a POSIX mode's permission bits
/// (02 §2.6's read-only rwx display): nine positions — user, group,
/// other — with suid/sgid/sticky folded into the execute slots the
/// standard way (s/S, s/S, t/T). The mode's file-type bits are ignored;
/// the kind column already names them. Char codes, not literals, keep
/// the localization contract free of glyph plumbing.
String ghostFormatPosixModeSymbolic(int mode) {
  final out = StringBuffer();
  const shifts = [6, 3, 0];
  const specials = [0x800, 0x400, 0x200];
  for (var triplet = 0; triplet < 3; triplet++) {
    final bits = (mode >> shifts[triplet]) & 7;
    out.writeCharCode((bits & 4) != 0 ? 0x72 : 0x2D); // r or -
    out.writeCharCode((bits & 2) != 0 ? 0x77 : 0x2D); // w or -
    final execute = (bits & 1) != 0;
    if ((mode & specials[triplet]) == 0) {
      out.writeCharCode(execute ? 0x78 : 0x2D); // x or -
    } else if (triplet == 2) {
      out.writeCharCode(execute ? 0x74 : 0x54); // t or T
    } else {
      out.writeCharCode(execute ? 0x73 : 0x53); // s or S
    }
  }
  return out.toString();
}

/// The mode's permission bits as four-digit octal (02 §2.6's octal
/// display): 0755, 0644, 4755 — the leading digit carries suid/sgid/
/// sticky, so nothing the symbolic render folded into its slots is lost.
String ghostFormatPosixModeOctal(int mode) =>
    (mode & 0xFFF).toRadixString(8).padLeft(4, '0');

/// A name that cannot go back over the wire unchanged (02 §13's
/// flagged-name rule): U+FFFD means the listing's decode already lost
/// bytes, and any path built from it would name a different file. Rows
/// badge such names, spell the reason into their semantics label, and
/// withhold rename.
bool ghostFileNameIsFlagged(String name) => name.contains('�');

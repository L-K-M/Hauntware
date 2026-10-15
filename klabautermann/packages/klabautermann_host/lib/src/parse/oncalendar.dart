/// Parser for `systemd-analyze calendar` output (03 §7.7): the
/// `Original form`, `Normalized form` and one elapse per `Next elapse`
/// or later-run row (`Iter. #N:` in systemd 242 to 252, `Iteration #N`
/// from 253), each optionally followed by `(in UTC)` and `From now`
/// detail lines.
library;

import 'package:meta/meta.dart';

import 'parse_result.dart';

/// One predicted elapse of `systemd-analyze calendar` (03 §7.7).
@immutable
final class OnCalendarElapse {
  const OnCalendarElapse({this.text, this.atUtc, this.fromNow});

  /// The timestamp text exactly as printed (`Tue 2026-10-13 21:45:00
  /// UTC` or a zone abbreviation we cannot resolve).
  final String? text;

  /// The instant in UTC: the `(in UTC)` line decoded, or the timestamp
  /// itself when it ends in `UTC` or `GMT` and that line is missing,
  /// which systemd-analyze omits in a zone whose offset is zero all year.
  final DateTime? atUtc;

  /// The `From now` detail (`9h left`).
  final String? fromNow;

  Map<String, Object?> toJson() => {
    'text': text,
    'atUtc': atUtc?.toIso8601String(),
    'fromNow': fromNow,
  };
}

/// The result of `systemd-analyze calendar [--iterations=N]` (03 §7.7).
@immutable
final class OnCalendarResult {
  OnCalendarResult({
    this.originalForm,
    this.normalizedForm,
    List<OnCalendarElapse>? elapses,
  }) : elapses = List.unmodifiable(elapses ?? []);

  /// The expression echo (`Original form:`), null when the input was
  /// already the normalized form: systemd-analyze then omits the line,
  /// so callers key a read by the expression they sent.
  final String? originalForm;

  /// The canonical systemd spelling (`Normalized form:`), what the
  /// jobs view offers to write back.
  final String? normalizedForm;

  /// `Next elapse` plus every later-run row, in order.
  final List<OnCalendarElapse> elapses;

  Map<String, Object?> toJson() => {
    'originalForm': originalForm,
    'normalizedForm': normalizedForm,
    'elapses': elapses.map((e) => e.toJson()).toList(),
  };
}

/// Parses `systemd-analyze calendar` output; never throws. Lines the
/// parser does not know (error text systemd-analyze prints before dying)
/// collect as warnings.
ParseResult<OnCalendarResult> parseOnCalendar(String raw) {
  final warnings = <String>[];
  String? original, normalized;
  final elapses = <OnCalendarElapse>[];
  var text = <String>[];
  DateTime? utc;
  String? fromNow;
  var open = false;

  void flush() {
    if (!open) return;
    elapses.add(
      OnCalendarElapse(
        text: text.isEmpty ? null : text.join('\n'),
        atUtc: utc ?? (text.length == 1 ? _zeroOffsetStamp(text.single) : null),
        fromNow: fromNow,
      ),
    );
    text = [];
    utc = null;
    fromNow = null;
    open = false;
  }

  final iter = RegExp(r'^Iter(?:\.|ation) #\d+:');
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('Original form:')) {
      original = t.substring(14).trim();
      continue;
    }
    if (t.startsWith('Normalized form:')) {
      normalized = t.substring(16).trim();
      continue;
    }
    if (t.startsWith('Next elapse:')) {
      flush();
      open = true;
      text = [t.substring(12).trim()];
      continue;
    }
    if (iter.hasMatch(t)) {
      flush();
      open = true;
      // The timestamp may follow the colon or sit on the next line.
      final rest = t.substring(t.indexOf(':') + 1).trim();
      text = rest.isEmpty ? <String>[] : [rest];
      continue;
    }
    if (t.startsWith('(in UTC):')) {
      utc ??= _utcStamp(t.substring(9).trim());
      continue;
    }
    if (t.startsWith('From now:')) {
      fromNow ??= t.substring(9).trim();
      continue;
    }
    // An unrecognised line inside an elapse is extra timestamp text
    // (`when` lines); outside it is noise worth a warning.
    if (open) {
      text.add(t);
    } else {
      warnings.add('oncalendar: unexpected line "$t"');
    }
  }
  flush();
  if (elapses.isEmpty && normalized == null) {
    warnings.add('oncalendar: no elapse rows');
  }
  return ParseResult(
    OnCalendarResult(
      originalForm: original,
      normalizedForm: normalized,
      elapses: elapses,
    ),
    warnings,
  );
}

/// An elapse without an `(in UTC)` line as an instant. systemd-analyze
/// leaves that line out when `in_utc_timezone()` holds, an offset of
/// zero all year, where stamps end in `UTC` or, as in Etc/GMT and
/// Atlantic/Reykjavik, `GMT`.
DateTime? _zeroOffsetStamp(String s) =>
    _utcStamp(s.endsWith(' GMT') ? '${s.substring(0, s.length - 4)} UTC' : s);

/// `Wed 2026-10-15 14:45:00 UTC` to a UTC instant; other zone
/// abbreviations are ambiguous and stay null (the row text survives in
/// [OnCalendarElapse.text]).
DateTime? _utcStamp(String s) {
  if (!s.endsWith(' UTC')) return null;
  final sp = s.indexOf(' ');
  if (sp < 0) return null;
  return DateTime.tryParse('${s.substring(sp + 1, s.length - 4).trim()}Z');
}

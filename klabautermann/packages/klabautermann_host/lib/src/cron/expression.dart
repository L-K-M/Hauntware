/// The cron expression grammar (03 §7.7): five fields `minute hour
/// day-of-month month day-of-week` with lists, ranges, steps, month and
/// weekday names, and the `@` macros. `parse` returns null on malformed
/// input and never throws: a crontab line that does not parse is a
/// warning upstream, not an exception.
library;

import 'package:meta/meta.dart';

/// The `@` macros of crontab(5), including cronie's aliases.
enum CronMacro {
  reboot,
  yearly,
  annually,
  monthly,
  weekly,
  daily,
  midnight,
  hourly,
}

/// One comma item of a cron field as written, with month and weekday
/// names resolved to numbers (03 §7.7). Schedule descriptions word these
/// items, so `*/10` and `0,10,20,30,40,50` keep their different shapes
/// although both expand to the same minutes.
@immutable
final class CronFieldItem {
  const CronFieldItem._({this.start, this.end, this.step});

  /// The first value; null for `*`. A day-of-week 7 stays 7 (sunday).
  final int? start;

  /// The last value of `a-b`, or the field maximum for a bare `a/n`;
  /// null for a single value and for `*`.
  final int? end;

  /// The `/n` step; null when none was written.
  final int? step;

  /// The item in cron syntax (`*`, `*/n`, `a`, `a-b`, `a-b/n`), which
  /// determines every field: only the parser builds items.
  String get canonical {
    final base = start == null
        ? '*'
        : end == null
        ? '$start'
        : '$start-$end';
    return step == null ? base : '$base/$step';
  }
}

/// The five fields of a clock schedule as written (03 §7.7).
@immutable
final class CronFields {
  CronFields._({
    required List<CronFieldItem> minute,
    required List<CronFieldItem> hour,
    required List<CronFieldItem> dayOfMonth,
    required List<CronFieldItem> month,
    required List<CronFieldItem> dayOfWeek,
  }) : minute = List.unmodifiable(minute),
       hour = List.unmodifiable(hour),
       dayOfMonth = List.unmodifiable(dayOfMonth),
       month = List.unmodifiable(month),
       dayOfWeek = List.unmodifiable(dayOfWeek);

  final List<CronFieldItem> minute, hour, dayOfMonth, month, dayOfWeek;

  /// Each field as its items' canonical text joined by commas, which
  /// loses nothing because no canonical item holds a comma.
  Map<String, Object?> toJson() {
    String items(List<CronFieldItem> f) => f.map((i) => i.canonical).join(',');
    return {
      'minute': items(minute),
      'hour': items(hour),
      'dayOfMonth': items(dayOfMonth),
      'month': items(month),
      'dayOfWeek': items(dayOfWeek),
    };
  }
}

/// A parsed cron schedule (03 §7.7). Fields hold the allowed values as
/// sets; matching follows Vixie/cronie semantics, including the
/// day-of-month/day-of-week OR rule when both are restricted and the
/// cronie "star" flag that a field carries when its text starts with
/// `*` (so `*/2` still counts as unrestricted there).
@immutable
final class CronExpression {
  CronExpression._({
    required Set<int> minutes,
    required Set<int> hours,
    required Set<int> monthDays,
    required Set<int> months,
    required Set<int> weekDays,
    required this.domStar,
    required this.dowStar,
    this.macro,
    this.fields,
    this.isReboot = false,
  }) : minutes = Set.unmodifiable(minutes),
       hours = Set.unmodifiable(hours),
       monthDays = Set.unmodifiable(monthDays),
       months = Set.unmodifiable(months),
       weekDays = Set.unmodifiable(weekDays);

  /// `@reboot`: runs at daemon start, never on a clock time.
  factory CronExpression.reboot() => CronExpression._(
    minutes: const {},
    hours: const {},
    monthDays: const {},
    months: const {},
    weekDays: const {},
    domStar: false,
    dowStar: false,
    macro: CronMacro.reboot,
    isReboot: true,
  );

  /// Minutes 0-59.
  final Set<int> minutes;

  /// Hours 0-23.
  final Set<int> hours;

  /// Days of month 1-31.
  final Set<int> monthDays;

  /// Months 1-12 (jan is 1).
  final Set<int> months;

  /// Days of week 0-6 (sunday is 0; a written 7 normalizes to 0).
  final Set<int> weekDays;

  /// The cronie DOM_STAR/DOW_STAR flags: set when the field text starts
  /// with `*`. The day rule is AND when either is flagged, OR when both
  /// are restricted (crontab(5)).
  final bool domStar, dowStar;

  /// `@reboot` has no clock schedule.
  final bool isReboot;

  /// The macro the schedule was written as, or null for five fields.
  final CronMacro? macro;

  /// The fields as written (a macro's as expanded); null for `@reboot`.
  /// Not part of [toJson], which carries the expanded sets.
  final CronFields? fields;

  /// Whether [wall] (a zone-local wall-clock time) matches.
  bool matches(DateTime wall) {
    if (isReboot) return false;
    if (!minutes.contains(wall.minute) ||
        !hours.contains(wall.hour) ||
        !months.contains(wall.month)) {
      return false;
    }
    final dom = monthDays.contains(wall.day);
    // DateTime weekday runs monday..sunday as 1..7; cron uses 0..6 with
    // sunday 0, so the modulus maps 7 to 0.
    final dow = weekDays.contains(wall.weekday % 7);
    if (domStar || dowStar) return dom && dow;
    return dom || dow;
  }

  /// Parses a 5-field expression or an `@` macro; null when malformed.
  static CronExpression? parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('@')) {
      final macro = _macros[t.toLowerCase()];
      if (macro == null) {
        return t.toLowerCase() == '@reboot' ? CronExpression.reboot() : null;
      }
      return _parseFields(macro.$2.split(' '), macro: macro.$1);
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    return _parseFields(parts);
  }

  static CronExpression? _parseFields(List<String> parts, {CronMacro? macro}) {
    final minute = _items(parts[0], 0, 59);
    final hour = _items(parts[1], 0, 23);
    final dayOfMonth = _items(parts[2], 1, 31);
    final month = _items(parts[3], 1, 12, names: _monthNames);
    final dayOfWeek = _items(parts[4], 0, 7, names: _weekdayNames);
    if (minute == null ||
        hour == null ||
        dayOfMonth == null ||
        month == null ||
        dayOfWeek == null) {
      return null;
    }
    final weekDays = _expand(dayOfWeek, 0, 7);
    // A written 7 means sunday (crontab(5)).
    if (weekDays.remove(7)) weekDays.add(0);
    return CronExpression._(
      minutes: _expand(minute, 0, 59),
      hours: _expand(hour, 0, 23),
      monthDays: _expand(dayOfMonth, 1, 31),
      months: _expand(month, 1, 12),
      weekDays: weekDays,
      domStar: parts[2].startsWith('*'),
      dowStar: parts[4].startsWith('*'),
      macro: macro,
      fields: CronFields._(
        minute: minute,
        hour: hour,
        dayOfMonth: dayOfMonth,
        month: month,
        dayOfWeek: dayOfWeek,
      ),
    );
  }

  /// One field: a comma list of `base[/step]` where base is `*`, a
  /// value, or `a-b`; a bare `a/n` steps a..max (crontab(5)).
  static List<CronFieldItem>? _items(
    String field,
    int min,
    int max, {
    Map<String, int>? names,
  }) {
    if (field.isEmpty) return null;
    final out = <CronFieldItem>[];
    for (final item in field.split(',')) {
      if (item.isEmpty) return null;
      final slash = item.indexOf('/');
      final base = slash < 0 ? item : item.substring(0, slash);
      int? step;
      if (slash >= 0) {
        step = int.tryParse(item.substring(slash + 1)) ?? -1;
        if (step <= 0) return null;
      }
      if (base == '*') {
        out.add(CronFieldItem._(step: step));
        continue;
      }
      int lo, hi;
      final dash = base.indexOf('-');
      if (dash < 0) {
        lo = _value(base, names) ?? -1;
        hi = slash < 0 ? lo : max;
      } else {
        lo = _value(base.substring(0, dash), names) ?? -1;
        hi = _value(base.substring(dash + 1), names) ?? -1;
      }
      // hi < lo rejects both an inverted a-b and a bare a/n whose start
      // lies above the maximum, as cronie does.
      if (lo < min || hi > max || hi < lo) return null;
      final single = dash < 0 && slash < 0;
      out.add(CronFieldItem._(start: lo, end: single ? null : hi, step: step));
    }
    return out;
  }

  /// The values [items] select in a field ranging [min] to [max].
  static Set<int> _expand(List<CronFieldItem> items, int min, int max) {
    final out = <int>{};
    for (final item in items) {
      final lo = item.start ?? min;
      final hi = item.end ?? item.start ?? max;
      for (var v = lo; v <= hi; v += item.step ?? 1) {
        out.add(v);
      }
    }
    return out;
  }

  static int? _value(String token, Map<String, int>? names) {
    final named = names?[token.toLowerCase()];
    if (named != null) return named;
    if (token.isEmpty || token.length > 4) return null;
    final digits = int.tryParse(token);
    return digits != null && digits >= 0 ? digits : null;
  }

  static const _macros = {
    '@yearly': (CronMacro.yearly, '0 0 1 1 *'),
    '@annually': (CronMacro.annually, '0 0 1 1 *'),
    '@monthly': (CronMacro.monthly, '0 0 1 * *'),
    '@weekly': (CronMacro.weekly, '0 0 * * 0'),
    '@daily': (CronMacro.daily, '0 0 * * *'),
    '@midnight': (CronMacro.midnight, '0 0 * * *'),
    '@hourly': (CronMacro.hourly, '0 * * * *'),
  };

  static const _monthNames = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const _weekdayNames = {
    'sun': 0,
    'mon': 1,
    'tue': 2,
    'wed': 3,
    'thu': 4,
    'fri': 5,
    'sat': 6,
  };

  Map<String, Object?> toJson() => {
    'minutes': minutes.toList()..sort(),
    'hours': hours.toList()..sort(),
    'monthDays': monthDays.toList()..sort(),
    'months': months.toList()..sort(),
    'weekDays': weekDays.toList()..sort(),
    'domStar': domStar,
    'dowStar': dowStar,
    'isReboot': isReboot,
  };
}

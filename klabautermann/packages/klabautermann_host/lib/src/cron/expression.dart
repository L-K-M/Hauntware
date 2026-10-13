/// The cron expression grammar (03 §7.7): five fields `minute hour
/// day-of-month month day-of-week` with lists, ranges, steps, month and
/// weekday names, and the `@` macros. `parse` returns null on malformed
/// input and never throws: a crontab line that does not parse is a
/// warning upstream, not an exception.
library;

import 'package:meta/meta.dart';

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
      return _parseFields(macro.split(' '));
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    return _parseFields(parts);
  }

  static CronExpression? _parseFields(List<String> parts) {
    final minutes = _field(parts[0], 0, 59);
    final hours = _field(parts[1], 0, 23);
    final monthDays = _field(parts[2], 1, 31);
    final months = _field(parts[3], 1, 12, names: _monthNames);
    final weekDays = _field(parts[4], 0, 7, names: _weekdayNames);
    if (minutes == null ||
        hours == null ||
        monthDays == null ||
        months == null ||
        weekDays == null) {
      return null;
    }
    // A written 7 means sunday (crontab(5)).
    if (weekDays.remove(7)) weekDays.add(0);
    return CronExpression._(
      minutes: minutes,
      hours: hours,
      monthDays: monthDays,
      months: months,
      weekDays: weekDays,
      domStar: parts[2].startsWith('*'),
      dowStar: parts[4].startsWith('*'),
    );
  }

  /// One field: a comma list of `base[/step]` where base is `*`, a
  /// value, or `a-b`; a bare `a/n` steps a..max (crontab(5)).
  static Set<int>? _field(
    String field,
    int min,
    int max, {
    Map<String, int>? names,
  }) {
    if (field.isEmpty) return null;
    final out = <int>{};
    for (final item in field.split(',')) {
      if (item.isEmpty) return null;
      final slash = item.indexOf('/');
      final base = slash < 0 ? item : item.substring(0, slash);
      var step = 1;
      if (slash >= 0) {
        step = int.tryParse(item.substring(slash + 1)) ?? -1;
        if (step <= 0) return null;
      }
      int lo, hi;
      if (base == '*') {
        lo = min;
        hi = max;
      } else {
        final dash = base.indexOf('-');
        if (dash < 0) {
          lo = _value(base, names) ?? -1;
          hi = slash < 0 ? lo : max;
        } else {
          lo = _value(base.substring(0, dash), names) ?? -1;
          hi = _value(base.substring(dash + 1), names) ?? -1;
          if (hi < lo) return null;
        }
      }
      if (lo < min || hi > max) return null;
      for (var v = lo; v <= hi; v += step) {
        out.add(v);
      }
    }
    return out.isEmpty ? null : out;
  }

  static int? _value(String token, Map<String, int>? names) {
    final named = names?[token.toLowerCase()];
    if (named != null) return named;
    if (token.isEmpty || token.length > 4) return null;
    final digits = int.tryParse(token);
    return digits != null && digits >= 0 ? digits : null;
  }

  static const _macros = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@hourly': '0 * * * *',
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

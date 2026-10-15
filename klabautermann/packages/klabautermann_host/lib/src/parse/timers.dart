/// Parser for the `timers` slow-collector payload (03 §6.4, §7.7):
/// `systemctl list-timers --all --output=json` on systemd 246+
/// (`== timers_json ==`), else the columnar `list-timers --all` table
/// (`== timers_text ==`) sliced at its header's column offsets. Also the
/// on-demand `timer_detail` payload of one timer (D57).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import '../jobs/schedule.dart' show MonotonicBase, MonotonicSchedule;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Which shape the timers block took (03 §6.4): JSON on systemd 246+,
/// the columnar text table below it, or absent output.
enum TimerListFormat { json, text, none }

/// One row of `systemctl list-timers --all` (03 §7.7).
@immutable
final class SystemdTimer {
  const SystemdTimer({
    required this.unit,
    this.activates,
    this.nextUs,
    this.leftUs,
    this.lastUs,
    this.passedUs,
    this.nextText,
    this.lastText,
  });

  /// The timer unit name (`foo.timer`).
  final String unit;

  /// The unit the timer activates (`foo.service`).
  final String? activates;

  /// Absolute epoch microseconds for the next and last elapse, or null
  /// when never (`n/a`) or unparseable.
  final int? nextUs, lastUs;

  /// Relative microseconds for the LEFT and PASSED columns.
  final int? leftUs, passedUs;

  /// The raw NEXT and LAST cells on the text path: they are rendered in
  /// the server's local zone with a zone abbreviation we cannot resolve,
  /// so non-UTC text stays unconverted (03 §6.1 "unknown stays unknown").
  final String? nextText, lastText;

  /// NEXT as a UTC instant, when known.
  DateTime? get nextUtc => nextUs == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(nextUs!, isUtc: true);

  /// LAST as a UTC instant, when known.
  DateTime? get lastUtc => lastUs == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(lastUs!, isUtc: true);

  Map<String, Object?> toJson() => {
    'unit': unit,
    'activates': activates,
    'nextUs': nextUs,
    'leftUs': leftUs,
    'lastUs': lastUs,
    'passedUs': passedUs,
    'nextText': nextText,
    'lastText': lastText,
  };
}

/// One `timers` tick (03 §6.4).
@immutable
final class TimersSnapshot {
  TimersSnapshot({
    List<SystemdTimer>? timers,
    this.format = TimerListFormat.none,
    this.timeoutAbsent = false,
  }) : timers = List.unmodifiable(timers ?? []);

  /// All loaded timers, in `systemctl` order.
  final List<SystemdTimer> timers;

  /// Which wire shape the block held.
  final TimerListFormat format;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3).
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'timers': timers.map((t) => t.toJson()).toList(),
    'format': format.name,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses a `timers` section payload; never throws (03 §6.5).
ParseResult<TimersSnapshot> parseTimers(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('timers ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }

  List<SystemdTimer> timers = const [];
  var format = TimerListFormat.none;
  if (split.blocks['timers_json'] case final lines?) {
    format = TimerListFormat.json;
    timers = _parseTimersJson(lines, warnings);
  } else if (split.blocks['timers_text'] case final lines?) {
    format = TimerListFormat.text;
    timers = _parseTimersText(lines, warnings);
  } else {
    warnings.add('timers: no timers block');
  }

  return ParseResult(
    TimersSnapshot(
      timers: timers,
      format: format,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}

/// One timer's triggers and randomized delay from the on-demand
/// `timer_detail` read (03 §7.7, D57).
@immutable
final class TimerDetail {
  TimerDetail({
    List<String>? calendar,
    List<MonotonicSchedule>? monotonic,
    this.randomizedDelay,
    this.timeoutAbsent = false,
  }) : calendar = List.unmodifiable(calendar ?? []),
       monotonic = List.unmodifiable(monotonic ?? []);

  /// The `OnCalendar=` expressions in systemd's normalized form, in
  /// `systemctl show` order.
  final List<String> calendar;

  /// The monotonic triggers (`OnBootSec=` and the like).
  final List<MonotonicSchedule> monotonic;

  /// `RandomizedDelaySec=`, zero when unset; null when `systemctl show`
  /// printed no value it could read (systemd before 229 has none).
  final Duration? randomizedDelay;

  /// True when the payload reports the read ran without `timeout`.
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'calendar': calendar,
    'monotonic': monotonic.map((m) => m.toJson()).toList(),
    'randomizedDelayUs': randomizedDelay?.inMicroseconds,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses a `timer_detail` section payload; never throws (03 §6.5). It
/// holds `systemctl show` lines in any order, one per calendar and per
/// monotonic trigger, and the randomized delay:
///
/// ```text
/// TimersCalendar={ OnCalendar=*-*-* 06,18:00:00 ; next_elapse=Thu ... UTC }
/// TimersMonotonic={ OnBootUSec=15min ; next_elapse=15min }
/// RandomizedDelayUSec=12h
/// ```
///
/// Spans are systemd's `format_timespan` text (`1h 30min`, `1.500000s`,
/// `0`).
ParseResult<TimerDetail> parseTimerDetail(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final calendar = <String>[];
  final monotonic = <MonotonicSchedule>[];
  Duration? delay;
  var timeoutAbsent = false;
  for (final line in raw.split('\n')) {
    if (line == kTimeoutAbsentMarker) {
      timeoutAbsent = true;
      continue;
    }
    final eq = line.indexOf('=');
    if (eq < 0) {
      if (line.trim().isNotEmpty) warnings.add('timer_detail: "$line"');
      continue;
    }
    final value = line.substring(eq + 1).trim();
    switch (line.substring(0, eq)) {
      case _ when value.isEmpty:
        break;
      case 'TimersCalendar':
        final (base, expression) = _trigger(value);
        if (base == 'OnCalendar' && expression.isNotEmpty) {
          calendar.add(expression);
        } else {
          warnings.add('timer_detail: calendar trigger "$value"');
        }
      case 'TimersMonotonic':
        final (base, span) = _trigger(value);
        final b = _monotonicBases[base];
        final us = _timespanUs(span);
        if (b == null || us == null) {
          warnings.add('timer_detail: monotonic trigger "$value"');
        } else {
          monotonic.add(
            MonotonicSchedule(
              base: b,
              span: Duration(microseconds: us),
            ),
          );
        }
      case 'RandomizedDelayUSec':
        final us = _timespanUs(value);
        if (us == null) {
          warnings.add('timer_detail: randomized delay "$value"');
        } else {
          delay = Duration(microseconds: us);
        }
      default:
        warnings.add('timer_detail: "$line"');
    }
  }
  return ParseResult(
    TimerDetail(
      calendar: calendar,
      monotonic: monotonic,
      randomizedDelay: delay,
      timeoutAbsent: timeoutAbsent,
    ),
    warnings,
  );
}

/// `{ <base>=<value> ; next_elapse=<next> }` as its base and value; an
/// empty base when the shape does not match. A calendar expression holds
/// neither ` ; ` nor braces, so the last ` ; next_elapse=` ends it.
(String, String) _trigger(String braced) {
  if (!braced.startsWith('{') || !braced.endsWith('}')) return ('', '');
  final inner = braced.substring(1, braced.length - 1);
  final end = inner.lastIndexOf(' ; next_elapse=');
  final pair = (end < 0 ? inner : inner.substring(0, end)).trim();
  final eq = pair.indexOf('=');
  if (eq < 0) return ('', '');
  return (pair.substring(0, eq), pair.substring(eq + 1).trim());
}

/// `systemctl show` names a monotonic base by its bus property
/// (`OnBootUSec`), the unit setting's name with `USec` for `Sec`.
final _monotonicBases = {
  for (final b in MonotonicBase.values)
    '${b.setting.substring(0, b.setting.length - 3)}USec': b,
};

/// `list-timers --output=json` rows: objects with `next`, `left`,
/// `last`, `passed` (finite microseconds or null), `unit` and
/// `activates`. Unknown keys are tolerated.
List<SystemdTimer> _parseTimersJson(List<String> lines, List<String> warnings) {
  final text = lines.join('\n').trim();
  if (text.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    warnings.add('timers_json: not JSON');
    return const [];
  }
  if (decoded is! List) {
    warnings.add('timers_json: JSON is not a list');
    return const [];
  }
  final out = <SystemdTimer>[];
  for (final e in decoded) {
    if (e is! Map) {
      warnings.add('timers_json: non-object row skipped');
      continue;
    }
    final unit = e['unit'];
    if (unit is! String || unit.isEmpty) {
      warnings.add('timers_json: row without a unit name skipped');
      continue;
    }
    out.add(
      SystemdTimer(
        unit: unit,
        activates: _str(e['activates']),
        nextUs: _instantUsec(e['next'], warnings),
        leftUs: _usec(e['left']),
        lastUs: _instantUsec(e['last'], warnings),
        passedUs: _usec(e['passed']),
      ),
    );
  }
  return out;
}

/// A JSON value as a string without throwing (the `activates` field).
String? _str(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  return null;
}

/// A JSON microsecond field: an integer, a numeric string, or null.
int? _usec(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

/// The furthest instant [DateTime] holds either side of the epoch, in
/// microseconds (100,000,000 days).
const _maxInstantUs = 8640000000000000000;

/// An absolute microsecond field ([_usec]) that [SystemdTimer.nextUtc] and
/// [SystemdTimer.lastUtc] can convert: a value beyond [DateTime]'s range
/// warns and reads as unknown instead of making those getters throw.
int? _instantUsec(Object? v, List<String> warnings) {
  final us = _usec(v);
  if (us == null || (us >= -_maxInstantUs && us <= _maxInstantUs)) return us;
  warnings.add('timers_json: instant out of range');
  return null;
}

/// The columnar `list-timers --all` table: column content starts at the
/// header's field offsets, so rows slice positionally (timestamps and
/// spans may contain single spaces). Legend and hint lines are dropped;
/// anything that does not end in a `*.timer` unit warns and skips.
List<SystemdTimer> _parseTimersText(List<String> lines, List<String> warnings) {
  final out = <SystemdTimer>[];
  List<int>? columns;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    if (columns == null) {
      // The first non-empty line is the header; its six column starts
      // delimit every row.
      columns = _timerColumns(line);
      if (columns == null) {
        warnings.add('timers_text: no column header');
        return const [];
      }
      continue;
    }
    if (RegExp(r'^\d+ timers? listed\.$').hasMatch(line.trim()) ||
        line.startsWith('Pass --all')) {
      continue;
    }
    final cells = <String>[];
    for (var i = 0; i < columns.length; i++) {
      final from = columns[i];
      if (from >= line.length) {
        cells.add('');
        continue;
      }
      final to = i + 1 < columns.length ? columns[i + 1] : line.length;
      cells.add(line.substring(from, to.clamp(from, line.length)).trim());
    }
    if (cells.length < 6 || !cells[4].endsWith('.timer')) {
      warnings.add('timers_text: malformed row "${line.trim()}"');
      continue;
    }
    out.add(
      SystemdTimer(
        unit: cells[4],
        activates: cells[5].isEmpty || cells[5] == '-' ? null : cells[5],
        nextText: cells[0].isEmpty ? null : cells[0],
        nextUs: _timerTimestampUs(cells[0]),
        leftUs: _timespanUs(cells[1]),
        lastText: cells[2].isEmpty ? null : cells[2],
        lastUs: _timerTimestampUs(cells[2]),
        passedUs: _timespanUs(cells[3]),
      ),
    );
  }
  if (columns == null) warnings.add('timers_text: empty block');
  return out;
}

/// Column start offsets of the `list-timers` header, or null when it is
/// not the `NEXT LEFT LAST PASSED UNIT ACTIVATES` shape.
List<int>? _timerColumns(String header) {
  const names = ['NEXT', 'LEFT', 'LAST', 'PASSED', 'UNIT', 'ACTIVATES'];
  final offsets = <int>[];
  var at = 0;
  for (final name in names) {
    final i = header.indexOf(name, at);
    if (i < 0) return null;
    offsets.add(i);
    at = i + name.length;
  }
  return offsets;
}

/// Parses a `list-timers` timestamp cell (`Mon 2023-11-13 21:45:58 UTC`)
/// into epoch microseconds. Only a trailing `UTC` converts; other zone
/// abbreviations are ambiguous and stay null. `n/a` yields null.
int? _timerTimestampUs(String cell) {
  final t = cell.trim();
  if (t.isEmpty || t == 'n/a' || t == '-') return null;
  if (!t.endsWith(' UTC')) return null;
  // Drop the weekday prefix and the UTC suffix.
  final sp = t.indexOf(' ');
  if (sp < 0) return null;
  final stamp = '${t.substring(sp + 1, t.length - 4).trim()}Z';
  return DateTime.tryParse(stamp)?.microsecondsSinceEpoch;
}

/// Parses a systemd span (`20h left`, `1 day ago`, `1min 30.500000s`,
/// `0`, `n/a`) into microseconds; unknown unit words, a fraction of a
/// unit above a second and spans past [_maxSpanUs] yield null.
int? _timespanUs(String cell) {
  var t = cell.trim();
  if (t.isEmpty || t == 'n/a' || t == '-') return null;
  if (t == '0') return 0;
  for (final tail in const [' left', ' ago']) {
    if (t.endsWith(tail)) t = t.substring(0, t.length - tail.length);
  }
  // The relative format spells units as words (`1 day 3h`).
  t = t.replaceAllMapped(_spacedUnit, (m) => '${m[1]}${m[2]}');
  var total = 0;
  var matched = false;
  for (final part in t.split(RegExp(r'\s+'))) {
    final m = _spanPart.firstMatch(part);
    if (m == null) return null;
    final unit = _spanUnits[m[3]!];
    final n = int.tryParse(m[1]!);
    if (unit == null || n == null || n > (_maxSpanUs - total) ~/ unit) {
      return null;
    }
    total += n * unit;
    // A fraction of a unit: `.5s` is 500,000 µs, digits past µs dropped.
    // format_timespan prints one only below a minute, on `s` or `ms`; a
    // larger unit times six digits could overflow.
    if (m[2] case final f?) {
      if (unit > _usPerSecond) return null;
      total += int.parse(f) * unit ~/ _pow10[f.length];
      if (total > _maxSpanUs) return null;
    }
    matched = true;
  }
  return matched ? total : null;
}

/// One span word: digits, an optional fraction of up to six digits, and
/// a unit (`30.500000s`, `2h`, `1day`).
final _spanPart = RegExp(r'^(\d{1,18})(?:\.(\d{1,6}))?([^\d\s.]+)$');

/// A number and the unit word after it (`1 day`, `2 weeks`).
final _spacedUnit = RegExp(r'(\d) ([a-z]+)\b');

const _pow10 = [1, 10, 100, 1000, 10000, 100000, 1000000];

const _usPerSecond = 1000000;

/// The longest span read: 2^62 µs, about 146,000 years.
const _maxSpanUs = 1 << 62;

/// systemd `format_timespan` units, in microseconds.
const _spanUnits = {
  'us': 1,
  'µs': 1,
  'μs': 1,
  'usec': 1,
  'ms': 1000,
  'msec': 1000,
  's': 1000000,
  'sec': 1000000,
  'min': 60000000,
  'h': 3600000000,
  'hr': 3600000000,
  'd': 86400000000,
  'day': 86400000000,
  'days': 86400000000,
  'w': 604800000000,
  'week': 604800000000,
  'weeks': 604800000000,
  'month': 2629800000000,
  'months': 2629800000000,
  'y': 31557600000000,
  'year': 31557600000000,
  'years': 31557600000000,
};

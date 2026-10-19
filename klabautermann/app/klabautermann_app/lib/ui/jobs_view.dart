import 'package:intl/intl.dart' show DateFormat;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';

/// The most clock times a schedule lists as times ("at 6:00 AM and 6:00
/// PM") before it reads its minute and hour fields apart.
const int _maxListedTimes = 6;

/// The shapes whose phrase repeats ("every 15 minutes").
const _repeating = {_Shape.all, _Shape.step, _Shape.rangeStep};

/// A cron field's kind, which picks its ARB phrase and how its values read.
enum _Field { minute, hour, dayOfMonth, month, dayOfWeek }

/// How a cron field is written, which its phrase follows (03 §7.7: worded
/// from the fields as written, so `*/15` and `0,15,30,45` read apart).
enum _Shape {
  /// `*`.
  all,

  /// `*/n` whose runs fall an even interval apart ([_evenStep]).
  step,

  /// `a-b/n`, or `a/n`, which runs to the field's maximum, or a `*/n`
  /// that restarts with its field's cycle at an uneven interval.
  rangeStep,

  /// One value.
  value,

  /// Anything else: values, ranges and steps in a list.
  other,
}

/// [schedule] in words (JOB-02): a cron schedule from its fields as
/// written or its macro, with its `CRON_TZ`; an `OnCalendar=` expression
/// verbatim, as server data (the client never rewords systemd's calendar
/// grammar); a monotonic trigger's span and base.
String scheduleText(AppLocalizations l10n, ScheduleDescription schedule) =>
    switch (schedule) {
      CronSchedule() => _cronText(l10n, schedule),
      CalendarSchedule(:final normalized) => l10n.jobsScheduleCalendar(
        normalized,
      ),
      MonotonicSchedule(:final base, :final span) => l10n.jobsScheduleMonotonic(
        base.name,
        spanText(l10n, span),
      ),
    };

String _cronText(AppLocalizations l10n, CronSchedule schedule) {
  final fields = schedule.fields;
  final dayMatch = schedule.dayMatch;
  final macro = schedule.macro;
  final sentence = macro != null || fields == null || dayMatch == null
      ? l10n.jobsScheduleCronMacro((macro ?? CronMacro.reboot).name)
      : l10n.jobsScheduleCron(_fieldsText(l10n, fields, dayMatch));
  final zone = schedule.timeZone;
  return zone == null ? sentence : l10n.jobsScheduleInZone(sentence, zone);
}

String _fieldsText(
  AppLocalizations l10n,
  CronFields fields,
  CronDayMatch dayMatch,
) {
  String? restricted(_Field field, List<CronFieldItem> items) =>
      _shapeOf(field, items) == _Shape.all
      ? null
      : _fieldText(l10n, field, items);

  final dom = restricted(_Field.dayOfMonth, fields.dayOfMonth);
  final dow = restricted(_Field.dayOfWeek, fields.dayOfWeek);
  final days = switch ((dom, dow)) {
    (final dom?, final dow?) => switch (dayMatch) {
      CronDayMatch.either => l10n.jobsCronDaysEither(dom, dow),
      CronDayMatch.both => l10n.jobsCronDaysBoth(dom, dow),
    },
    _ => dom ?? dow,
  };
  return [
    _timeText(l10n, fields.minute, fields.hour),
    ?days,
    ?restricted(_Field.month, fields.month),
  ].reduce(l10n.jobsPhrasePair);
}

/// The minute and hour fields: clock times when both hold single values
/// only; otherwise each field's phrase. A minute step needs no "every
/// hour", which a list of minutes does, and beside a repeating minute a
/// stepped hour reads as the hours it spans, not as a second "every 2
/// hours".
String _timeText(
  AppLocalizations l10n,
  List<CronFieldItem> minute,
  List<CronFieldItem> hour,
) {
  final minutes = _singleValues(minute);
  final hours = _singleValues(hour);
  if (minutes != null &&
      hours != null &&
      minutes.length * hours.length <= _maxListedTimes) {
    final clock = DateFormat.jm(l10n.localeName);
    final times = [
      for (final h in hours)
        for (final m in minutes) DateTime.utc(2000, 1, 1, h, m),
    ]..sort();
    return l10n.jobsCronTimes(_list(l10n, times.map(clock.format).toList()));
  }

  final minuteText = _fieldText(l10n, _Field.minute, minute);
  final minuteShape = _shapeOf(_Field.minute, minute);
  final hourShape = _shapeOf(_Field.hour, hour);
  if (hourShape == _Shape.all &&
      (minuteShape == _Shape.all || minuteShape == _Shape.step)) {
    return minuteText;
  }
  if (_repeating.contains(minuteShape) &&
      (hourShape == _Shape.step || hourShape == _Shape.rangeStep)) {
    final item = hour.single;
    final (min, max) = _bounds(_Field.hour);
    return l10n.jobsPhrasePair(
      minuteText,
      l10n.jobsCronHoursStepped(
        _value(l10n, _Field.hour, item.start ?? min),
        _value(l10n, _Field.hour, item.end ?? max),
        _step(item)!,
      ),
    );
  }
  return l10n.jobsPhrasePair(minuteText, _fieldText(l10n, _Field.hour, hour));
}

/// The values of [items] when each is a single value, else null.
List<int>? _singleValues(List<CronFieldItem> items) {
  final values = <int>[];
  for (final item in items) {
    final start = item.start;
    if (start == null || item.end != null || _step(item) != null) return null;
    values.add(start);
  }
  return values;
}

/// [item]'s step, null when none was written or it is 1, which steps
/// over nothing.
int? _step(CronFieldItem item) => item.step == 1 ? null : item.step;

_Shape _shapeOf(_Field field, List<CronFieldItem> items) {
  if (items.length != 1) return _Shape.other;

  final item = items.single;
  final step = _step(item);
  if (item.start == null) {
    if (step == null) return _Shape.all;
    return _evenStep(field, step) ? _Shape.step : _Shape.rangeStep;
  }
  if (step != null) return _Shape.rangeStep;
  return item.end == null ? _Shape.value : _Shape.other;
}

/// Whether `*/[step]` in [field] runs an even interval apart: the step
/// divides the field's cycle. `*/45` minutes runs at :00 and :45, 45 then
/// 15 minutes apart, and a month's varying length leaves no day-of-month
/// step even, so those read with their bounds.
bool _evenStep(_Field field, int step) {
  if (field == _Field.dayOfMonth) return false;

  final (min, max) = _bounds(field);
  return (max - min + 1) % step == 0;
}

String _fieldText(
  AppLocalizations l10n,
  _Field field,
  List<CronFieldItem> items,
) {
  final shape = _shapeOf(field, items).name;
  final item = items.first;
  final step = _step(item) ?? 1;
  final first = _value(l10n, field, item.start ?? _bounds(field).$1);
  final last = _value(l10n, field, _end(field, item) ?? _bounds(field).$2);
  final listed = _list(l10n, [
    for (final i in items) _itemText(l10n, field, i),
  ]);
  return switch (field) {
    _Field.minute => l10n.jobsCronMinute(shape, listed, step, first, last),
    _Field.hour => l10n.jobsCronHour(shape, listed, step, first, last),
    _Field.dayOfMonth => l10n.jobsCronDayOfMonth(
      shape,
      listed,
      step,
      first,
      last,
    ),
    _Field.month => l10n.jobsCronMonth(shape, listed, step, first, last),
    _Field.dayOfWeek => l10n.jobsCronDayOfWeek(
      shape,
      listed,
      step,
      first,
      last,
    ),
  };
}

/// One item of a field's list: a value, a range, or a step over a range.
String _itemText(AppLocalizations l10n, _Field field, CronFieldItem item) {
  final (min, max) = _bounds(field);
  final step = _step(item);
  final first = _value(l10n, field, item.start ?? min);
  final end = _end(field, item);
  if (step != null) {
    return l10n.jobsCronItemStep(step, first, _value(l10n, field, end ?? max));
  }
  if (item.start == null) {
    return l10n.jobsCronRange(first, _value(l10n, field, max));
  }
  return end == null
      ? first
      : l10n.jobsCronRange(first, _value(l10n, field, end));
}

/// [item]'s last value as worded: a day-of-week range from 0 to 7 runs
/// from Sunday to Sunday again, the whole week, which ends on Saturday.
int? _end(_Field field, CronFieldItem item) =>
    field == _Field.dayOfWeek && item.start == 0 && item.end == 7
    ? 6
    : item.end;

/// [field]'s first and last value (crontab(5)), which a `*` spans; a
/// written day of week 7 is Sunday too, so a week ends on Saturday here.
(int, int) _bounds(_Field field) => switch (field) {
  _Field.minute => (0, 59),
  _Field.hour => (0, 23),
  _Field.dayOfMonth => (1, 31),
  _Field.month => (1, 12),
  _Field.dayOfWeek => (0, 6),
};

/// A value of [field]: a month or weekday by name in the UI locale, other
/// fields as numbers.
String _value(AppLocalizations l10n, _Field field, int value) =>
    switch (field) {
      _Field.month => DateFormat.MMMM(
        l10n.localeName,
      ).format(DateTime.utc(2000, value)),
      // 1 January 2023 was a Sunday, cron's day 0 and 7.
      _Field.dayOfWeek => DateFormat.EEEE(
        l10n.localeName,
      ).format(DateTime.utc(2023, 1, 1 + value % 7)),
      _ => value.toString(),
    };

/// [items] as one list in the catalog's words: "a", "a and b", "a, b and
/// c".
String _list(AppLocalizations l10n, List<String> items) {
  if (items.length == 1) return items.single;
  if (items.length == 2) return l10n.jobsListPair(items.first, items.last);
  return l10n.jobsListMore(items.first, _list(l10n, items.sublist(1)));
}

/// [span] in its nonzero units, largest first ("1 h 30 min"), with its
/// seconds to the millisecond, which the catalog's decimal format keeps;
/// a smaller remainder rounds.
String spanText(AppLocalizations l10n, Duration span) {
  final micros = span.inMicroseconds % Duration.microsecondsPerMinute;
  final parts = [
    if (span.inDays > 0) l10n.jobsSpanDays(span.inDays),
    if (span.inHours % 24 > 0) l10n.jobsSpanHours(span.inHours % 24),
    if (span.inMinutes % 60 > 0) l10n.jobsSpanMinutes(span.inMinutes % 60),
  ];
  if (micros > 0 || parts.isEmpty) {
    parts.add(l10n.jobsSpanSeconds(micros / Duration.microsecondsPerSecond));
  }
  return parts.reduce(l10n.jobsSpanPair);
}

/// Which side of UTC an offset lies on, which its ARB phrase selects.
enum _OffsetSign { zero, minus, plus }

/// [offset] as a UTC offset, "UTC+02:00", or "UTC" at zero.
String utcOffsetText(AppLocalizations l10n, Duration offset) {
  final sign = offset == Duration.zero
      ? _OffsetSign.zero
      : offset.isNegative
      ? _OffsetSign.minus
      : _OffsetSign.plus;
  final size = offset.abs();
  return l10n.jobsUtcOffset(
    sign.name,
    DateTime.utc(2000, 1, 1, size.inHours, size.inMinutes % 60),
  );
}

/// The wall clock of the zone at [offset] at [utc], as a UTC-flagged
/// value the date formats print field by field.
DateTime wallAt(DateTime utc, Duration offset) => utc.toUtc().add(offset);

/// [run] at its zone's offset with that offset (CN-02): a run skipped
/// into a DST change shows the instant it fires, its note the time it
/// was written for.
String runTimeText(AppLocalizations l10n, CronRun run) => l10n.jobsRunTime(
  wallAt(run.atUtc, run.offset),
  utcOffsetText(l10n, run.offset),
);

/// What a DST change does to [run] (03 §7.7, D58), or null when nothing.
String? runNote(AppLocalizations l10n, CronRun run) => switch (run.dst) {
  CronDst.none => null,
  CronDst.gap => l10n.jobsRunGap(run.wall),
  CronDst.overlap => l10n.jobsRunOverlap(run.wall),
  CronDst.nearTransition => l10n.jobsRunNearTransition,
};

/// Why a row lists no runs, in words, with the engine's limits.
String runsUnknownText(AppLocalizations l10n, JobRunsUnknown reason) =>
    l10n.jobsRunsUnknown(
      reason.name,
      kCronLinesEvaluated,
      // In whole years.
      kCronHorizonDays ~/ 365,
    );

/// The row's name: a cron line's command, a periodic script's name or a
/// timer's unit, all server data.
String jobTitle(JobEntry job) => switch (job) {
  CronJobEntry(:final job) => job.command,
  PeriodicJobEntry(:final entry) => entry.name,
  TimerJobEntry(:final timer) => timer.unit,
};

/// Where the row comes from, with the user it runs as where the line
/// names one (JOB-01).
String sourceText(AppLocalizations l10n, JobEntry job) => switch (job) {
  CronJobEntry(:final job) => switch ((job.source, job.user)) {
    (kOwnCrontabSource, _) => l10n.jobsSourceOwnCrontab,
    // Another user's crontab, which JOB-03 read in admin mode.
    (final source, final user?) when source == userCrontabSource(user) =>
      l10n.jobsSourceUserCrontab(user),
    (final source, final user?) => l10n.jobsSourceAsUser(source, user),
    (final source, null) => source,
  },
  PeriodicJobEntry(:final directory) => directory,
  TimerJobEntry() => l10n.jobsSourceTimer,
};

/// A cron or periodic row's runs and why it has none; empty for a timer,
/// whose next elapse systemd lists.
(List<CronRun>, JobRunsUnknown?) cronRuns(JobEntry job) => switch (job) {
  CronJobEntry(:final nextRuns, :final runsUnknown) ||
  PeriodicJobEntry(
    :final nextRuns,
    :final runsUnknown,
  ) => (nextRuns, runsUnknown),
  TimerJobEntry() => (const [], null),
};

/// Whether [profile]'s systemd lists only one elapse of an `OnCalendar=`
/// expression: `systemd-analyze calendar --iterations` arrived in 242
/// (03 §7.7), so a single run there is not the whole list.
bool listsOneElapse(HostProfile? profile) {
  final version = profile?.systemdVersion;
  return version != null && version < kCalendarIterationsSystemd;
}

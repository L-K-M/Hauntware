/// Schedule descriptions for the unified jobs list (03 §7.7, JOB-02).
/// They carry no English: the app words each variant from ARB templates
/// (A11Y-05), and an `OnCalendar` expression is server data shown
/// verbatim.
library;

import 'package:meta/meta.dart';

import '../cron/expression.dart';
import '../parse/oncalendar.dart';

/// How a cron schedule combines day of month and day of week
/// (crontab(5)).
enum CronDayMatch {
  /// Both must match, because one of the two fields starts with `*`.
  both,

  /// Either may match, because both fields are restricted (the
  /// Vixie/cronie OR rule).
  either,
}

/// What one job trigger says, as data the app words (03 §7.7).
@immutable
sealed class ScheduleDescription {
  const ScheduleDescription();

  Map<String, Object?> toJson();
}

/// A cron schedule: five fields or an `@` macro (03 §7.7).
final class CronSchedule extends ScheduleDescription {
  const CronSchedule({
    required this.text,
    required this.expression,
    this.timeZone,
  });

  /// Describes [text] through [CronExpression.parse]; null when it does
  /// not parse. [timeZone] is the `CRON_TZ` in effect for the line.
  static CronSchedule? parse(String text, {String? timeZone}) {
    final expression = CronExpression.parse(text);
    if (expression == null) return null;
    return CronSchedule(
      text: text.trim(),
      expression: expression,
      timeZone: timeZone,
    );
  }

  /// The schedule text as the crontab line wrote it.
  final String text;

  final CronExpression expression;

  /// The `CRON_TZ` the line is evaluated in; null for the server zone.
  final String? timeZone;

  /// The macro the line used, or null for five fields.
  CronMacro? get macro => expression.macro;

  /// The fields as written; null for `@reboot`.
  CronFields? get fields => expression.fields;

  /// How the day fields combine; null for `@reboot`.
  CronDayMatch? get dayMatch {
    if (fields == null) return null;
    return expression.domStar || expression.dowStar
        ? CronDayMatch.both
        : CronDayMatch.either;
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'cron',
    'text': text,
    'macro': macro?.name,
    'fields': fields?.toJson(),
    'dayMatch': dayMatch?.name,
    'timeZone': timeZone,
  };
}

/// A systemd `OnCalendar=` trigger in its normalized form, shown
/// verbatim: the client never reimplements systemd's calendar grammar
/// (03 §7.7).
final class CalendarSchedule extends ScheduleDescription {
  CalendarSchedule({required this.normalized, List<OnCalendarElapse>? elapses})
    : elapses = elapses == null ? null : List.unmodifiable(elapses);

  /// The trigger from a `systemd-analyze calendar` result; null when
  /// the result has no normalized form (systemd rejected the expression).
  static CalendarSchedule? fromResult(OnCalendarResult result) {
    final normalized = result.normalizedForm;
    if (normalized == null || normalized.isEmpty) return null;
    return CalendarSchedule(normalized: normalized, elapses: result.elapses);
  }

  /// The canonical systemd spelling (`*-*-* 00:00:00`).
  final String normalized;

  /// The elapses `systemd-analyze calendar` predicted, in order; null
  /// when the expression has not been evaluated on the host.
  final List<OnCalendarElapse>? elapses;

  @override
  Map<String, Object?> toJson() => {
    'type': 'calendar',
    'normalized': normalized,
    'elapses': elapses?.map((e) => e.toJson()).toList(),
  };
}

/// The event a monotonic timer trigger counts from (systemd.timer(5)).
enum MonotonicBase {
  active('OnActiveSec'),
  boot('OnBootSec'),
  startup('OnStartupSec'),
  unitActive('OnUnitActiveSec'),
  unitInactive('OnUnitInactiveSec');

  const MonotonicBase(this.setting);

  /// The timer unit setting that names this base.
  final String setting;
}

/// A monotonic systemd timer trigger: [span] after [base] (03 §7.7).
final class MonotonicSchedule extends ScheduleDescription {
  const MonotonicSchedule({required this.base, required this.span});

  final MonotonicBase base;

  final Duration span;

  @override
  Map<String, Object?> toJson() => {
    'type': 'monotonic',
    'base': base.name,
    'spanUs': span.inMicroseconds,
  };
}

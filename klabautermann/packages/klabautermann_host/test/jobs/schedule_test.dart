// Schedule description tests (03 §7.7, JOB-02): cron fields keep their
// written shape (macros, steps, lists, ranges, names) for wording, the
// day-match rule follows crontab(5), and OnCalendar and monotonic
// triggers stay plain server data.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

List<String> _items(List<CronFieldItem> field) =>
    field.map((i) => i.canonical).toList();

void main() {
  group('cron', () {
    test('a macro keeps its name and the fields it expands to', () {
      final s = CronSchedule.parse('@daily')!;
      expect(s.macro, CronMacro.daily);
      expect(_items(s.fields!.minute), ['0']);
      expect(_items(s.fields!.hour), ['0']);
      expect(_items(s.fields!.dayOfMonth), ['*']);
      expect(s.dayMatch, CronDayMatch.both);
      expect(CronSchedule.parse('@ANNUALLY')!.macro, CronMacro.annually);
    });

    test('every clock macro maps to its name and crontab(5) fields', () {
      const macros = {
        '@yearly': (CronMacro.yearly, '0 0 1 1 *'),
        '@annually': (CronMacro.annually, '0 0 1 1 *'),
        '@monthly': (CronMacro.monthly, '0 0 1 * *'),
        '@weekly': (CronMacro.weekly, '0 0 * * 0'),
        '@daily': (CronMacro.daily, '0 0 * * *'),
        '@midnight': (CronMacro.midnight, '0 0 * * *'),
        '@hourly': (CronMacro.hourly, '0 * * * *'),
      };
      for (final MapEntry(key: text, value: (macro, fields))
          in macros.entries) {
        final s = CronSchedule.parse(text)!;
        expect(s.macro, macro, reason: text);
        expect(s.fields!.toJson().values.join(' '), fields, reason: text);
      }
    });

    test('@reboot has a macro but no fields or day rule', () {
      final s = CronSchedule.parse('@reboot')!;
      expect(s.macro, CronMacro.reboot);
      expect(s.fields, isNull);
      expect(s.dayMatch, isNull);
    });

    test('steps keep their base: */n, a/n and a-b/n', () {
      final s = CronSchedule.parse('*/10 9-17/4 5/7 * *')!;
      expect(s.macro, isNull);
      expect(s.fields!.minute.single.start, isNull);
      expect(s.fields!.minute.single.step, 10);
      expect(_items(s.fields!.minute), ['*/10']);
      expect(_items(s.fields!.hour), ['9-17/4']);
      // A bare a/n steps to the field maximum (crontab(5)).
      expect(_items(s.fields!.dayOfMonth), ['5-31/7']);
      // The expanded sets agree with the written items.
      expect(s.expression.minutes, {0, 10, 20, 30, 40, 50});
      expect(s.expression.monthDays, {5, 12, 19, 26});
    });

    test('lists keep each item, with names resolved to numbers', () {
      final s = CronSchedule.parse('0,30 8,20 1,15 jan,jul-sep mon-fri,7')!;
      expect(_items(s.fields!.minute), ['0', '30']);
      expect(_items(s.fields!.hour), ['8', '20']);
      expect(_items(s.fields!.month), ['1', '7-9']);
      // A written 7 stays 7 in the items; the set maps it to sunday 0.
      expect(_items(s.fields!.dayOfWeek), ['1-5', '7']);
      expect(s.expression.weekDays, {0, 1, 2, 3, 4, 5});
    });

    test('a list and a step that expand alike stay distinct', () {
      final step = CronSchedule.parse('*/15 * * * *')!;
      final list = CronSchedule.parse('0,15,30,45 * * * *')!;
      expect(step.expression.minutes, list.expression.minutes);
      expect(_items(step.fields!.minute), ['*/15']);
      expect(_items(list.fields!.minute), ['0', '15', '30', '45']);
    });

    test('restricting both day fields makes either match', () {
      expect(CronSchedule.parse('0 0 1 * mon')!.dayMatch, CronDayMatch.either);
      expect(CronSchedule.parse('0 0 */2 * mon')!.dayMatch, CronDayMatch.both);
      expect(CronSchedule.parse('0 0 1 * *')!.dayMatch, CronDayMatch.both);
    });

    test('a malformed schedule has no description', () {
      expect(CronSchedule.parse('61 * * * *'), isNull);
      expect(CronSchedule.parse('@fortnightly'), isNull);
      expect(CronSchedule.parse(''), isNull);
    });

    test('JSON carries the written fields, macro and CRON_TZ', () {
      final s = CronSchedule.parse(
        ' 15 3 * * sun ',
        timeZone: 'Europe/Berlin',
      )!;
      expect(s.toJson(), {
        'type': 'cron',
        'text': '15 3 * * sun',
        'macro': null,
        'fields': {
          'minute': '15',
          'hour': '3',
          'dayOfMonth': '*',
          'month': '*',
          'dayOfWeek': '0',
        },
        'dayMatch': 'both',
        'timeZone': 'Europe/Berlin',
      });
    });
  });

  group('calendar', () {
    test('a systemd-analyze result gives the normalized form and elapses', () {
      final result = parseOnCalendar(
        '  Original form: daily\n'
        'Normalized form: *-*-* 00:00:00\n'
        '    Next elapse: Thu 2026-10-15 00:00:00 UTC\n'
        '       From now: 11h left\n',
      ).value;
      final s = CalendarSchedule.fromResult(result)!;
      expect(s.normalized, '*-*-* 00:00:00');
      // A UTC server zone prints no `(in UTC)` line; the stamp is UTC.
      expect(s.elapses!.single.atUtc, DateTime.utc(2026, 10, 15));
      expect(s.elapses!.single.text, 'Thu 2026-10-15 00:00:00 UTC');
      expect(s.toJson()['type'], 'calendar');
    });

    test('a rejected expression has no description', () {
      final result = parseOnCalendar(
        'Failed to parse calendar specification "bogus": Invalid argument\n',
      ).value;
      expect(CalendarSchedule.fromResult(result), isNull);
    });

    test('elapses stay null until the host evaluates the expression', () {
      final s = CalendarSchedule(normalized: 'Mon *-*-* 06:00:00');
      expect(s.elapses, isNull);
      expect(s.toJson(), {
        'type': 'calendar',
        'normalized': 'Mon *-*-* 06:00:00',
        'elapses': null,
      });
    });
  });

  group('monotonic', () {
    test('bases name their timer settings', () {
      expect(MonotonicBase.values.map((b) => b.setting), [
        'OnActiveSec',
        'OnBootSec',
        'OnStartupSec',
        'OnUnitActiveSec',
        'OnUnitInactiveSec',
      ]);
    });

    test('JSON carries the base and the span in microseconds', () {
      const s = MonotonicSchedule(
        base: MonotonicBase.unitActive,
        span: Duration(hours: 6),
      );
      expect(s.toJson(), {
        'type': 'monotonic',
        'base': 'unitActive',
        'spanUs': 21600000000,
      });
    });
  });
}

// Cron expression grammar tests (03 §7.7): five fields, lists, ranges,
// steps, month and weekday names, the `@` macros and the Vixie/cronie
// day-of-month/day-of-week OR rule. `parse` returns null and never
// throws on malformed input.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('parse', () {
    test('a plain five-field expression', () {
      final e = CronExpression.parse('0 * * * *')!;
      expect(e.minutes, {0});
      expect(e.hours, hasLength(24));
      expect(e.monthDays, hasLength(31));
      expect(e.months, hasLength(12));
      expect(e.weekDays, hasLength(7));
      expect(e.domStar, isTrue);
      expect(e.dowStar, isTrue);
      expect(e.isReboot, isFalse);
    });

    test('lists, ranges and steps', () {
      final e = CronExpression.parse('5,10-20/5 */2 * * *')!;
      expect(e.minutes, {5, 10, 15, 20});
      expect(e.hours, {0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22});
      // `*/2` still carries the cronie star flag (crontab(5)).
      expect(e.domStar, isTrue);
    });

    test('a bare a/n steps from a to the field maximum', () {
      expect(CronExpression.parse('30/10 * * * *')!.minutes, {30, 40, 50});
    });

    test('a bounded step walks the range from its low end', () {
      expect(CronExpression.parse('* 9-17/4 * * *')!.hours, {9, 13, 17});
    });

    test('month and weekday names, including ranges', () {
      final e = CronExpression.parse('0 0 1 jan-mar mon,wed')!;
      expect(e.months, {1, 2, 3});
      expect(e.weekDays, {1, 3});
    });

    test('month and weekday names are case-insensitive', () {
      final e = CronExpression.parse('0 0 * JAN,JUL MON-FRI')!;
      expect(e.months, {1, 7});
      expect(e.weekDays, {1, 2, 3, 4, 5});
    });

    test('a written 7 normalizes to sunday 0', () {
      expect(CronExpression.parse('0 0 * * 7')!.weekDays, {0});
      expect(CronExpression.parse('0 0 * * 0')!.weekDays, {0});
    });

    test('macros expand to their five-field form', () {
      expect(CronExpression.parse('@hourly')!.minutes, {0});
      expect(CronExpression.parse('@daily')!.hours, {0});
      expect(CronExpression.parse('@weekly')!.weekDays, {0});
      expect(CronExpression.parse('@monthly')!.monthDays, {1});
      expect(CronExpression.parse('@yearly')!.months, {1});
      expect(CronExpression.parse('@annually')!.months, {1});
      expect(CronExpression.parse('@midnight')!.hours, {0});
    });

    test('@reboot parses to a reboot expression with no clock', () {
      final e = CronExpression.parse('@REBOOT')!;
      expect(e.isReboot, isTrue);
      expect(e.minutes, isEmpty);
      expect(e.matches(DateTime.utc(2026, 1, 1)), isFalse);
    });

    test('malformed expressions return null, never throw', () {
      for (final bad in const [
        '',
        '   ',
        '* * * *',
        '* * * * * *',
        '60 * * * *',
        '* 24 * * *',
        '* * 0 * *',
        '* * 32 * *',
        '* * * 13 *',
        '* * * * 8',
        '*/0 * * * *',
        '*/x * * * *',
        '5-1 * * * *',
        'a b c d e',
        '@nope',
        ', * * * *',
      ]) {
        expect(
          CronExpression.parse(bad),
          isNull,
          reason: 'should reject "$bad"',
        );
      }
    });
  });

  group('matches', () {
    test('day-of-month and day-of-week are OR when both are restricted', () {
      // Runs on the 13th OR on a Friday (crontab(5)).
      final e = CronExpression.parse('0 0 13 * fri')!;
      final friday = DateTime.utc(2026, 3, 6); // a Friday, not the 13th
      final thirteenth = DateTime.utc(2026, 4, 13); // a Monday
      expect(e.matches(friday), isTrue);
      expect(e.matches(thirteenth), isTrue);
      expect(e.matches(DateTime.utc(2026, 3, 10)), isFalse);
    });

    test('a starred day field turns the rule into AND', () {
      // `*/2` starts with `*`, so cronie ANDs the two day fields; the
      // 13th matches only when its weekday is in {sun, tue, thu, sat}.
      final e = CronExpression.parse('0 0 13 * */2')!;
      expect(
        DateTime.utc(2026, 6, 13).weekday % 7,
        6,
        reason: '2026-06-13 is a Saturday',
      );
      expect(e.matches(DateTime.utc(2026, 6, 13)), isTrue); // Saturday 13th
      expect(e.matches(DateTime.utc(2026, 3, 13)), isFalse); // Friday 13th
    });

    test('hour and minute gate the match', () {
      final e = CronExpression.parse('30 9 * * *')!;
      expect(e.matches(DateTime.utc(2026, 6, 1, 9, 30)), isTrue);
      expect(e.matches(DateTime.utc(2026, 6, 1, 9, 31)), isFalse);
      expect(e.matches(DateTime.utc(2026, 6, 1, 10, 30)), isFalse);
    });
  });
}

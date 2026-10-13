// Cron expression and next-run tests (03 §7.7): the five-field grammar
// with ranges, steps, names and macros, and next-run evaluation in a
// server time zone including DST gap and overlap annotation.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// A zone whose offset changes at fixed UTC instants, as the probe's
/// `tzName` lookup would supply through `ServerZone.offsetAt`.
ServerZone _zone(Duration before, Duration after, DateTime transition) =>
    ServerZone(
      offset: before,
      ianaName: 'Test/Zone',
      offsetAt: (utc) => utc.isBefore(transition) ? before : after,
    );

void main() {
  group('CronExpression.parse', () {
    test('steps, ranges and lists expand to value sets', () {
      final e = CronExpression.parse('*/15 9-17/4 1,15 * *')!;
      expect(e.minutes, {0, 15, 30, 45});
      expect(e.hours, {9, 13, 17});
      expect(e.monthDays, {1, 15});
      expect(e.months, hasLength(12));
    });

    test('month and weekday names are case-insensitive', () {
      final e = CronExpression.parse('0 0 * jan,jul mon-fri')!;
      expect(e.months, {1, 7});
      expect(e.weekDays, {1, 2, 3, 4, 5});
    });

    test('a written 7 normalizes to sunday', () {
      expect(CronExpression.parse('0 0 * * 7')!.weekDays, {0});
    });

    test('macros expand and @reboot carries no clock schedule', () {
      final weekly = CronExpression.parse('@weekly')!;
      expect(weekly.weekDays, {0});
      expect(weekly.matches(DateTime.utc(2026, 10, 18, 0, 0)), isTrue);
      final reboot = CronExpression.parse('@reboot')!;
      expect(reboot.isReboot, isTrue);
      expect(reboot.matches(DateTime.utc(2026, 10, 13)), isFalse);
    });

    test('malformed expressions parse to null, never throw', () {
      for (final bad in const [
        '60 * * * *',
        '* * * *',
        '* * * * * *',
        'a b c d e',
        '*/0 * * * *',
        '5-1 * * * *',
        '',
        '@nope',
      ]) {
        expect(CronExpression.parse(bad), isNull, reason: bad);
      }
    });

    test('both fields restricted means OR, otherwise AND', () {
      // Friday the 13th style: 13th OR friday.
      final or = CronExpression.parse('0 0 13 * 5')!;
      expect(or.matches(DateTime.utc(2026, 10, 16, 0, 0)), isTrue); // friday
      expect(or.matches(DateTime.utc(2026, 10, 13, 0, 0)), isTrue); // 13th
      expect(or.matches(DateTime.utc(2026, 10, 14, 0, 0)), isFalse);
      // One star: AND, so `*` weekday cannot widen the day.
      final and = CronExpression.parse('0 0 13 * *')!;
      expect(and.matches(DateTime.utc(2026, 10, 14, 0, 0)), isFalse);
    });
  });

  group('nextCronRuns', () {
    final utc = ServerZone(offset: Duration.zero, ianaName: 'UTC');

    test('a fixed offset maps wall time back to the instant', () {
      final zone = ServerZone(offset: const Duration(hours: 2));
      final runs = nextCronRuns(
        CronExpression.parse('30 2 * * *')!,
        afterUtc: DateTime.utc(2026, 10, 13, 0, 0),
        zone: zone,
        count: 1,
      );
      expect(runs.single.atUtc, DateTime.utc(2026, 10, 13, 0, 30));
      expect(runs.single.dst, CronDst.none);
      expect(runs.single.offset, const Duration(hours: 2));
    });

    test('count returns consecutive runs', () {
      final runs = nextCronRuns(
        CronExpression.parse('0 * * * *')!,
        afterUtc: DateTime.utc(2026, 10, 13, 5, 30),
        zone: utc,
        count: 3,
      );
      expect(runs.map((r) => r.atUtc), [
        DateTime.utc(2026, 10, 13, 6),
        DateTime.utc(2026, 10, 13, 7),
        DateTime.utc(2026, 10, 13, 8),
      ]);
    });

    test('a job inside the spring-forward gap fires at the transition', () {
      // Europe/Berlin, 2026-03-29 01:00 UTC: 02:00 -> 03:00.
      final zone = _zone(
        const Duration(hours: 1),
        const Duration(hours: 2),
        DateTime.utc(2026, 3, 29, 1),
      );
      final runs = nextCronRuns(
        CronExpression.parse('30 2 * * *')!,
        afterUtc: DateTime.utc(2026, 3, 29, 0, 0),
        zone: zone,
        count: 1,
      );
      expect(runs.single.dst, CronDst.gap);
      expect(runs.single.atUtc, DateTime.utc(2026, 3, 29, 1));
      // The annotated wall minute is the one the clock skipped.
      expect(runs.single.wall, DateTime.utc(2026, 3, 29, 2, 30));
    });

    test('a job inside the fall-back overlap fires on the first pass', () {
      // Europe/Berlin, 2026-10-25 01:00 UTC: 03:00 -> 02:00.
      final zone = _zone(
        const Duration(hours: 2),
        const Duration(hours: 1),
        DateTime.utc(2026, 10, 25, 1),
      );
      final runs = nextCronRuns(
        CronExpression.parse('30 2 * * *')!,
        afterUtc: DateTime.utc(2026, 10, 25, 0, 0),
        zone: zone,
        count: 1,
      );
      expect(runs.single.dst, CronDst.overlap);
      expect(runs.single.atUtc, DateTime.utc(2026, 10, 25, 0, 30));
    });

    test('a reboot expression and a zero count yield no runs', () {
      expect(
        nextCronRuns(
          CronExpression.parse('@reboot')!,
          afterUtc: DateTime.utc(2026, 10, 13),
          zone: utc,
        ),
        isEmpty,
      );
      expect(
        nextCronRuns(
          CronExpression.parse('* * * * *')!,
          afterUtc: DateTime.utc(2026, 10, 13),
          zone: utc,
          count: 0,
        ),
        isEmpty,
      );
    });
  });
}

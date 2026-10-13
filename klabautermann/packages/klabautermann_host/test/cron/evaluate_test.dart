// Next-run evaluation tests (03 §7.7): fixed-offset evaluation, the
// day jump, and DST gap/overlap annotation on a modelled Europe/Berlin
// zone. The evaluator is pure and never throws.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// A simple fixed-offset zone (no IANA rules): the probe offset alone.
ServerZone _fixed(int hours) => ServerZone(offset: Duration(hours: hours));

/// Europe/Berlin 2026 as a rule carrier: CET (+1) outside the DST
/// window, CEST (+2) inside it. Spring forward 2026-03-29T01:00Z,
/// fall back 2026-10-25T01:00Z.
Duration _berlin(DateTime utc) {
  final spring = DateTime.utc(2026, 3, 29, 1);
  final fall = DateTime.utc(2026, 10, 25, 1);
  final cest = utc.isBefore(fall) && !utc.isBefore(spring);
  return Duration(hours: cest ? 2 : 1);
}

ServerZone _berlinZone() => ServerZone(
  offset: const Duration(hours: 1),
  ianaName: 'Europe/Berlin',
  offsetAt: _berlin,
);

void main() {
  test('a daily job at a fixed offset', () {
    final runs = nextCronRuns(
      CronExpression.parse('30 9 * * *')!,
      afterUtc: DateTime.utc(2026, 6, 1, 10),
      zone: _fixed(2),
      count: 2,
    );
    expect(runs, hasLength(2));
    // Wall 09:30 on 2026-06-02 at +02:00 is 07:30Z.
    expect(runs.first.atUtc, DateTime.utc(2026, 6, 2, 7, 30));
    expect(runs.first.wall, DateTime.utc(2026, 6, 2, 9, 30));
    expect(runs.first.offset, const Duration(hours: 2));
    expect(runs.first.dst, CronDst.none);
    expect(runs.last.atUtc, DateTime.utc(2026, 6, 3, 7, 30));
  });

  test('an interval steps across midnight', () {
    final runs = nextCronRuns(
      CronExpression.parse('*/15 * * * *')!,
      afterUtc: DateTime.utc(2026, 6, 1, 23, 50),
      zone: _fixed(0),
      count: 3,
    );
    expect(runs.map((r) => r.atUtc).toList(), [
      DateTime.utc(2026, 6, 2, 0, 0),
      DateTime.utc(2026, 6, 2, 0, 15),
      DateTime.utc(2026, 6, 2, 0, 30),
    ]);
  });

  test('the day jump reaches a yearly schedule without walking minutes', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 0 1 1 *')!,
      afterUtc: DateTime.utc(2026, 6, 1),
      zone: _fixed(0),
      count: 1,
    );
    expect(runs.single.atUtc, DateTime.utc(2027, 1, 1));
  });

  test('a weekday schedule lands on the next matching weekday', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 8 * * mon')!,
      afterUtc: DateTime.utc(2026, 6, 1, 9), // Monday after 08:00
      zone: _fixed(0),
      count: 1,
    );
    expect(runs.single.atUtc, DateTime.utc(2026, 6, 8, 8));
  });

  test('a spring-forward gap run is annotated and fires at the jump', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 2 * * *')!,
      // Late on 2026-03-29, just before the 01:00Z offset jump.
      afterUtc: DateTime.utc(2026, 3, 29, 0, 30),
      zone: _berlinZone(),
      count: 1,
    );
    expect(runs.single.dst, CronDst.gap);
    expect(runs.single.atUtc, DateTime.utc(2026, 3, 29, 1));
    // The annotated wall minute is the one the clock skipped.
    expect(runs.single.wall, DateTime.utc(2026, 3, 29, 2));
  });

  test('a fall-back overlap run keeps the first occurrence', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 2 * * *')!,
      afterUtc: DateTime.utc(2026, 10, 24, 23, 30),
      zone: _berlinZone(),
      count: 1,
    );
    expect(runs.single.dst, CronDst.overlap);
    // First 02:00 wall at +02:00 is 00:00Z.
    expect(runs.single.atUtc, DateTime.utc(2026, 10, 25, 0));
  });

  test('ordinary mid-summer days are not annotated', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 2 * * *')!,
      afterUtc: DateTime.utc(2026, 6, 10, 12),
      zone: _berlinZone(),
      count: 2,
    );
    expect(runs.map((r) => r.dst).toList(), [CronDst.none, CronDst.none]);
    // Wall 02:00 at +02:00 is 00:00Z.
    expect(runs.first.atUtc, DateTime.utc(2026, 6, 11));
  });

  test('@reboot and nonpositive counts yield no runs', () {
    expect(
      nextCronRuns(
        CronExpression.parse('@reboot')!,
        afterUtc: DateTime.utc(2026, 6, 1),
        zone: _fixed(0),
      ),
      isEmpty,
    );
    expect(
      nextCronRuns(
        CronExpression.parse('* * * * *')!,
        afterUtc: DateTime.utc(2026, 6, 1),
        zone: _fixed(0),
        count: 0,
      ),
      isEmpty,
    );
  });

  test('an exhausted horizon stops the scan without throwing', () {
    final runs = nextCronRuns(
      CronExpression.parse('0 0 29 2 *')!,
      afterUtc: DateTime.utc(2026, 3, 1),
      zone: _fixed(0),
      count: 3,
      horizonDays: 30,
    );
    expect(runs, isEmpty);
  });
}

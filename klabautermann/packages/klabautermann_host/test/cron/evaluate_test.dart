// Next-run evaluation tests (03 §7.7): fixed-offset evaluation, the
// day jump, and DST gap, overlap and near-transition annotation on a
// modelled Europe/Berlin zone, for fixed-time and wildcard jobs. The
// evaluator is pure and never throws.
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

/// A zone at [std] hours outside `[spring, fall)` and an hour ahead
/// inside it, as a rule carrier.
ServerZone _dstZone(int std, DateTime spring, DateTime fall) => ServerZone(
  offset: Duration(hours: std),
  offsetAt: (utc) => Duration(
    hours: std + (!utc.isBefore(spring) && utc.isBefore(fall) ? 1 : 0),
  ),
);

/// The `(instant, annotation)` of the next five runs of [text] after
/// [after] in [zone], modelled Berlin by default.
List<(DateTime, CronDst)> _runs(
  String text,
  DateTime after, [
  ServerZone? zone,
]) => [
  for (final r in nextCronRuns(
    CronExpression.parse(text)!,
    afterUtc: after,
    zone: zone ?? _berlinZone(),
    count: 5,
  ))
    (r.atUtc, r.dst),
];

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

  test('stretches of days that cannot match are skipped whole', () {
    // Offset lookups count the scan steps: walking three hours of
    // minutes per skipped day took about 660,000 over the horizon.
    var lookups = 0;
    final zone = ServerZone(
      offset: Duration.zero,
      offsetAt: (_) {
        lookups++;
        return Duration.zero;
      },
    );
    List<DateTime> runs(String text) => [
      for (final r in nextCronRuns(
        CronExpression.parse(text)!,
        afterUtc: DateTime.utc(2026, 6, 1),
        zone: zone,
        count: 2,
      ))
        r.atUtc,
    ];

    expect(runs('0 0 30 2 *'), isEmpty);
    expect(lookups, lessThan(100));
    lookups = 0;
    expect(runs('0 0 29 2 *'), [
      DateTime.utc(2028, 2, 29),
      DateTime.utc(2032, 2, 29),
    ]);
    expect(lookups, lessThan(5000));
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

  test('a gap run fires when the wall day beside the gap does not match', () {
    // cron runs each skipped minute with that minute's own date. Modelled
    // Azores (-1, +0 from 2027-03-28T01:00Z) skips Sunday 00:00 to 00:59
    // after a Saturday; modelled Nuuk (-2, -1 at the same instant) skips
    // Saturday 23:00 to 23:59 before a Sunday.
    final spring = DateTime.utc(2027, 3, 28, 1);
    final fall = DateTime.utc(2027, 10, 31, 1);
    final after = DateTime.utc(2027, 3, 20);
    expect(_runs('30 0 * * 0', after, _dstZone(-1, spring, fall)).take(3), [
      (DateTime.utc(2027, 3, 21, 1, 30), CronDst.none),
      (spring, CronDst.gap),
      (DateTime.utc(2027, 4, 4, 0, 30), CronDst.none),
    ]);
    expect(_runs('30 23 * * 6', after, _dstZone(-2, spring, fall)).take(3), [
      (DateTime.utc(2027, 3, 21, 1, 30), CronDst.none),
      (spring, CronDst.gap),
      (DateTime.utc(2027, 4, 4, 0, 30), CronDst.none),
    ]);
  });

  test('a gap right before the first instant scanned still runs', () {
    // The scan starts at 01:00Z, the jump itself, whose minute before
    // is wall 01:59 CET: 02:30 was skipped and runs at the jump.
    expect(_runs('30 2 * * *', DateTime.utc(2026, 3, 29, 0, 59, 30)).first, (
      DateTime.utc(2026, 3, 29, 1),
      CronDst.gap,
    ));
    // From the jump on, that run is no longer strictly after.
    expect(_runs('30 2 * * *', DateTime.utc(2026, 3, 29, 1)).first, (
      DateTime.utc(2026, 3, 30, 0, 30),
      CronDst.none,
    ));
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

  test('a fixed-time job does not run again in the repeated hour', () {
    // Once the first 02:30 has passed, cron skips the repeated one.
    final runs = nextCronRuns(
      CronExpression.parse('30 2 * * *')!,
      afterUtc: DateTime.utc(2026, 10, 25, 0, 45),
      zone: _berlinZone(),
      count: 1,
    );
    expect(runs.single.atUtc, DateTime.utc(2026, 10, 26, 1, 30));
    expect(runs.single.dst, CronDst.none);
  });

  test('runs within an hour of a transition are marked near it', () {
    // A fixed-time job: its hour field does not start with `*`.
    List<(DateTime, CronDst)> runs(DateTime after, {ServerZone? zone}) =>
        _runs('30 0-23 * * *', after, zone ?? _berlinZone());

    // Spring forward at 01:00Z: wall 01:30 CET is half an hour before
    // the jump, 02:30 does not exist, 03:30 CEST is half an hour after.
    expect(runs(DateTime.utc(2026, 3, 28, 23)), [
      (DateTime.utc(2026, 3, 28, 23, 30), CronDst.none),
      (DateTime.utc(2026, 3, 29, 0, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 3, 29, 1), CronDst.gap),
      (DateTime.utc(2026, 3, 29, 1, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 3, 29, 2, 30), CronDst.none),
    ]);
    // A fixed offset has no transitions.
    expect(
      runs(DateTime.utc(2026, 3, 28, 23), zone: _fixed(1)).map((r) => r.$2),
      everyElement(CronDst.none),
    );
  });

  test('a wildcard job runs by the clock at transitions', () {
    // cronie and Debian's cron run a job whose minute or hour field
    // starts with `*` by the clock: not for minutes a forward jump
    // skips, and again in the hour a backward one repeats.
    expect(_runs('30 * * * *', DateTime.utc(2026, 3, 28, 23)), [
      (DateTime.utc(2026, 3, 28, 23, 30), CronDst.none),
      (DateTime.utc(2026, 3, 29, 0, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 3, 29, 1, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 3, 29, 2, 30), CronDst.none),
      (DateTime.utc(2026, 3, 29, 3, 30), CronDst.none),
    ]);
    expect(_runs('30 * * * *', DateTime.utc(2026, 10, 24, 23)), [
      (DateTime.utc(2026, 10, 24, 23, 30), CronDst.none),
      (DateTime.utc(2026, 10, 25, 0, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 10, 25, 1, 30), CronDst.nearTransition),
      (DateTime.utc(2026, 10, 25, 2, 30), CronDst.none),
      (DateTime.utc(2026, 10, 25, 3, 30), CronDst.none),
    ]);
    // `@hourly` is `0 * * * *`: wall 02:00 is skipped, 03:00 runs once.
    expect(_runs('@hourly', DateTime.utc(2026, 3, 29, 0, 30)).take(2), [
      (DateTime.utc(2026, 3, 29, 1), CronDst.nearTransition),
      (DateTime.utc(2026, 3, 29, 2), CronDst.none),
    ]);
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

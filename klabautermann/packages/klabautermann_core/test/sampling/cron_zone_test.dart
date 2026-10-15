// Cron next runs in the server's zone (03 §7.7, D57): the engine's
// jobs rows follow `package:timezone`'s rules for the probe's zone name
// across DST changes in both directions, keep a zone without DST
// steady, and fall back to the probe's fixed offset with a reason.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/cron_zone.dart';
import 'package:klabautermann_core/src/sampling/sample_results.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

int _epoch(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ 1000;

/// A probe that read [offset] and [zone] at [epoch].
HostProfile _profile(String? offset, [String? zone, int? epoch]) =>
    HostProfile(zoneOffset: offset, timezone: zone, epochSeconds: epoch);

/// A crontab of [lines] as the `cron` collector reports it.
CronSnapshot _crontab(String lines) => parseCron(
  '== crontab_meta ==\nrc=0\n== crontab ==\n$lines\n'
  '== etc_crontab ==\n== cron_d ==\n== cron_dirs ==\n',
  ParseContext.standard,
).value;

/// The `(instant, offset in minutes, annotation)` of each run of the
/// [index]th line.
List<(DateTime, int, CronDst)> _runs(CronResult result, [int index = 0]) => [
  for (final r in (result.jobs[index] as CronJobEntry).nextRuns)
    (r.atUtc, r.offset.inMinutes, r.dst),
];

// Probed in winter and in summer, so the rules, not the probe's offset,
// decide every run.
final _berlin = _profile('+0100', 'Europe/Berlin', _epoch(2026, 1, 15));
final _newYork = _profile('-0400', 'America/New_York', _epoch(2026, 6, 15));

void main() {
  group('Europe/Berlin', () {
    test('a spring-forward gap run fires at the jump', () {
      final result = cronResult(
        _crontab('30 2 * * * a'),
        _berlin,
        DateTime.utc(2026, 3, 28, 12),
      );
      expect(result.zoneName, 'Europe/Berlin');
      expect(result.zoneFallback, isNull);
      // 2026-03-29 02:30 does not exist: the clock jumps at 01:00Z.
      expect(_runs(result).take(2), [
        (DateTime.utc(2026, 3, 29, 1), 120, CronDst.gap),
        (DateTime.utc(2026, 3, 30, 0, 30), 120, CronDst.none),
      ]);
    });

    test('runs after the fall-back take CET', () {
      final overlap = cronResult(
        _crontab('30 2 * * * a'),
        _berlin,
        DateTime.utc(2026, 10, 24, 12),
      );
      // 02:30 occurs twice on 2026-10-25; cron runs the first, in CEST.
      expect(_runs(overlap).take(2), [
        (DateTime.utc(2026, 10, 25, 0, 30), 120, CronDst.overlap),
        (DateTime.utc(2026, 10, 26, 1, 30), 60, CronDst.none),
      ]);

      // The debian-12 fixture's weekly line, which #201 found at +120.
      final weekly = cronResult(
        _crontab('47 6 * * 7 a'),
        _berlin,
        DateTime.utc(2026, 10, 14, 12),
      );
      expect(_runs(weekly).take(2), [
        (DateTime.utc(2026, 10, 18, 4, 47), 120, CronDst.none),
        (DateTime.utc(2026, 10, 25, 5, 47), 60, CronDst.none),
      ]);
    });
  });

  group('America/New_York', () {
    test('a spring-forward gap run fires at the jump', () {
      final result = cronResult(
        _crontab('30 2 * * * a'),
        _newYork,
        DateTime.utc(2026, 3, 7, 12),
      );
      expect(result.zoneName, 'America/New_York');
      expect(_runs(result).take(2), [
        (DateTime.utc(2026, 3, 8, 7), -240, CronDst.gap),
        (DateTime.utc(2026, 3, 9, 6, 30), -240, CronDst.none),
      ]);
    });

    test('runs after the fall-back take EST', () {
      final overlap = cronResult(
        _crontab('30 1 * * * a'),
        _newYork,
        DateTime.utc(2026, 10, 31, 12),
      );
      // 01:30 occurs twice on 2026-11-01; the first is in EDT.
      expect(_runs(overlap).take(2), [
        (DateTime.utc(2026, 11, 1, 5, 30), -240, CronDst.overlap),
        (DateTime.utc(2026, 11, 2, 6, 30), -300, CronDst.none),
      ]);

      // The rhel-8 fixture's monthly line, which #201 found at -240.
      final monthly = cronResult(
        _crontab('42 4 1 * * a'),
        _newYork,
        DateTime.utc(2026, 10, 14, 12),
      );
      expect(_runs(monthly).first, (
        DateTime.utc(2026, 11, 1, 9, 42),
        -300,
        CronDst.none,
      ));
    });

    test('runs within an hour of the jump are marked near it', () {
      final result = cronResult(
        _crontab('30 * * * * a'),
        _newYork,
        DateTime.utc(2026, 3, 8, 5),
      );
      expect(_runs(result), [
        (DateTime.utc(2026, 3, 8, 5, 30), -300, CronDst.none),
        (DateTime.utc(2026, 3, 8, 6, 30), -300, CronDst.nearTransition),
        (DateTime.utc(2026, 3, 8, 7), -240, CronDst.gap),
        (DateTime.utc(2026, 3, 8, 7, 30), -240, CronDst.nearTransition),
        (DateTime.utc(2026, 3, 8, 8, 30), -240, CronDst.none),
      ]);
    });
  });

  test('a zone without DST keeps its offset all year', () {
    final kolkata = _profile('+0530', 'Asia/Kolkata', _epoch(2026, 6, 15));
    for (final after in [
      DateTime.utc(2026, 3, 27),
      DateTime.utc(2026, 10, 23),
    ]) {
      final result = cronResult(_crontab('0 3 * * * a'), kolkata, after);
      expect(result.zoneName, 'Asia/Kolkata');
      final runs = _runs(result);
      expect(runs, hasLength(5));
      expect(runs.map((r) => (r.$2, r.$3)), everyElement((330, CronDst.none)));
      // Wall 03:00 at +05:30 is 21:30Z the day before.
      expect(
        runs.first.$1,
        DateTime.utc(after.year, after.month, after.day, 21, 30),
      );
    }
  });

  group('the probe\'s fixed offset, with the reason', () {
    final october = DateTime.utc(2026, 10, 14, 12);

    test('for a zone the database does not know', () {
      final result = cronResult(
        _crontab('47 6 * * 7 a'),
        _profile('+0100', 'Mars/Olympus_Mons', _epoch(2026, 6, 15)),
        october,
      );
      expect(result.zoneName, isNull);
      expect(result.zoneFallback, CronZoneFallback.unknownZone);
      expect(_runs(result).take(2), [
        (DateTime.utc(2026, 10, 18, 5, 47), 60, CronDst.none),
        (DateTime.utc(2026, 10, 25, 5, 47), 60, CronDst.none),
      ]);
    });

    test('for a probe without a zone name', () {
      final result = cronResult(
        _crontab('0 3 * * * a'),
        _profile('+0000', null, _epoch(2026, 6, 15)),
        october,
      );
      expect(result.zoneFallback, CronZoneFallback.noZoneName);
      expect(_runs(result).first.$2, 0);
    });

    test('for a zone whose offset disagrees with the probe\'s', () {
      // A stale name: Berlin is +0200 in June, the server said +0000.
      final result = cronResult(
        _crontab('0 3 * * * a'),
        _profile('+0000', 'Europe/Berlin', _epoch(2026, 6, 15)),
        october,
      );
      expect(result.zoneName, isNull);
      expect(result.zoneFallback, CronZoneFallback.offsetMismatch);
      expect(_runs(result).first.$2, 0);
    });
  });

  test('without a clock reading the name is checked at evaluation', () {
    final noClock = _profile('+0100', 'Europe/Berlin');
    final january = cronResult(
      _crontab('0 3 * * * a'),
      noClock,
      DateTime.utc(2026, 1, 10),
    );
    expect(january.zoneName, 'Europe/Berlin');

    // Berlin is +0200 in July, so the probe's +0100 no longer confirms
    // the name.
    final july = cronResult(
      _crontab('0 3 * * * a'),
      noClock,
      DateTime.utc(2026, 7, 10),
    );
    expect(july.zoneName, isNull);
    expect(july.zoneFallback, CronZoneFallback.offsetMismatch);
  });

  test('a clock reading outside DateTime\'s range counts as none', () {
    // The server sends `epoch=`; past about 8.64e12 s no DateTime holds
    // it, and near the int64 limit the milliseconds overflow.
    for (final epoch in [
      99999999999999,
      -99999999999999,
      9223372036854775807,
    ]) {
      final profile = _profile('+0100', 'Europe/Berlin', epoch);
      expect(
        serverCronZone(profile, DateTime.utc(2026, 1, 10)).zoneName,
        'Europe/Berlin',
        reason: '$epoch',
      );
      expect(
        serverCronZone(profile, DateTime.utc(2026, 7, 10)).fallback,
        CronZoneFallback.offsetMismatch,
        reason: '$epoch',
      );
    }
  });

  test('without a probed offset only CRON_TZ lines have runs', () {
    final result = cronResult(
      _crontab('0 3 * * * a\nCRON_TZ=US/Eastern\n0 3 * * * b'),
      _profile(null, 'Europe/Berlin'),
      DateTime.utc(2026, 10, 14, 12),
    );
    expect(result.zoneName, isNull);
    expect(result.zoneFallback, isNull);
    final rows = result.jobs.cast<CronJobEntry>();
    expect(rows.first.runsUnknown, JobRunsUnknown.serverZoneUnknown);
    // A legacy alias from the database's backward links.
    expect(rows.last.nextRuns.first.offset, const Duration(hours: -4));
  });

  test('CRON_TZ zones come from the database', () {
    final result = cronResult(
      _crontab(
        'CRON_TZ=America/New_York\n30 2 * * * a\n'
        'CRON_TZ=Mars/Olympus_Mons\n30 2 * * * b',
      ),
      _berlin,
      DateTime.utc(2026, 3, 7, 12),
    );
    expect(_runs(result).first, (
      DateTime.utc(2026, 3, 8, 7),
      -240,
      CronDst.gap,
    ));
    expect(
      (result.jobs[1] as CronJobEntry).runsUnknown,
      JobRunsUnknown.timeZoneUnresolved,
    );
    expect(cronTzZone('Mars/Olympus_Mons', DateTime.utc(2026)), isNull);
  });

  test('no probe answer yet means no server zone', () {
    expect(serverCronZone(null, DateTime.utc(2026)), (
      zone: null,
      zoneName: null,
      fallback: null,
    ));
  });
}

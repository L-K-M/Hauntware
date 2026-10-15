// Cron next runs in the server's zone (03 §7.7, D58): the engine's
// jobs rows follow `package:timezone`'s rules for the probe's zone name
// across DST changes in both directions, keep a zone without DST
// steady, and fall back to the probe's fixed offset with a reason;
// CRON_TZ lines follow their own zone's clock.
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

    test('an hourly line runs in both passes of the repeated hour', () {
      // Debian's cron.hourly line: its hour field is `*`, so cron runs
      // it by the clock, at 02:17 CEST and again at 02:17 CET.
      final hourly = cronResult(
        _crontab('17 * * * * a'),
        _berlin,
        DateTime.utc(2026, 10, 24, 23, 30),
      );
      expect(_runs(hourly).take(3), [
        (DateTime.utc(2026, 10, 25, 0, 17), 120, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 1, 17), 60, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 2, 17), 60, CronDst.none),
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
      // A fixed-time job, so cron catches up the skipped 02:30.
      final result = cronResult(
        _crontab('30 0-23 * * * a'),
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
    // it, and near the int64 limits the milliseconds overflow; the
    // minimum is its own absolute value.
    for (final epoch in [
      99999999999999,
      -99999999999999,
      9223372036854775807,
      -9223372036854775808,
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
    // New York's 02:30 does not exist on 2026-03-08, and cron does not
    // catch up a CRON_TZ line's gap: the next run is the day after.
    expect(_runs(result).first, (
      DateTime.utc(2026, 3, 9, 6, 30),
      -240,
      CronDst.none,
    ));
    expect(
      (result.jobs[1] as CronJobEntry).runsUnknown,
      JobRunsUnknown.timeZoneUnresolved,
    );
    expect(cronTzZone('Mars/Olympus_Mons', DateTime.utc(2026)), isNull);
  });

  test('a gap beside a day the job skips runs at the jump', () {
    // Each server zone's spring jump skips minutes of a day the job
    // matches, next to a wall day it does not; cron runs them at the
    // jump. Each probe read the zone's standard offset.
    final winter = _epoch(2027, 1, 15);
    for (final (profile, line, after, jump) in [
      (
        _profile('-0100', 'Atlantic/Azores', winter),
        '30 0 * * 0',
        (2027, 3, 22),
        (2027, 3, 28, 1),
      ),
      (
        _profile('-0200', 'America/Nuuk', winter),
        '30 23 * * 6',
        (2027, 3, 22),
        (2027, 3, 28, 1),
      ),
      (
        _profile('-0400', 'America/Santiago', _epoch(2026, 6, 15)),
        '30 0 * * 0',
        (2026, 9, 1),
        (2026, 9, 6, 4),
      ),
      (
        _profile('-0500', 'America/Havana', winter),
        '30 0 * * 0',
        (2027, 3, 8),
        (2027, 3, 14, 5),
      ),
    ]) {
      final at = DateTime.utc(after.$1, after.$2, after.$3);
      final result = cronResult(_crontab('$line a'), profile, at);
      expect(result.zoneName, profile.timezone);
      final (run, _, dst) = _runs(result).first;
      expect(
        (run, dst),
        (DateTime.utc(jump.$1, jump.$2, jump.$3, jump.$4), CronDst.gap),
        reason: profile.timezone,
      );
    }
  });

  group('a CRON_TZ line follows its own zone\'s clock', () {
    // cronie converts each of its minutes into the line's zone and
    // matches there, and runs only wildcard jobs while its own zone
    // repeats an hour [R: cron.c find_jobs]. The server is in Berlin.
    test('its zone\'s gap is missed, even at the server\'s jump', () {
      final result = cronResult(
        _crontab('CRON_TZ=Europe/Berlin\n30 2 * * * a'),
        _berlin,
        DateTime.utc(2026, 3, 28, 12),
      );
      // A line without CRON_TZ would run at the jump, 01:00Z.
      expect(_runs(result).take(2), [
        (DateTime.utc(2026, 3, 30, 0, 30), 120, CronDst.none),
        (DateTime.utc(2026, 3, 31, 0, 30), 120, CronDst.none),
      ]);
    });

    test('a fall-back apart from the server\'s runs a fixed time twice', () {
      final result = cronResult(
        _crontab('CRON_TZ=America/New_York\n30 1 * * * a'),
        _berlin,
        DateTime.utc(2026, 10, 31, 12),
      );
      // 01:30 occurs in EDT and again in EST on 2026-11-01.
      expect(_runs(result).take(3), [
        (DateTime.utc(2026, 11, 1, 5, 30), -240, CronDst.nearTransition),
        (DateTime.utc(2026, 11, 1, 6, 30), -300, CronDst.nearTransition),
        (DateTime.utc(2026, 11, 2, 6, 30), -300, CronDst.none),
      ]);
    });

    test('a fall-back with the server\'s runs a fixed time once', () {
      // London and Berlin both fall back at 2026-10-25T01:00Z; the
      // second 01:30 lies in the server's repeated hour.
      final result = cronResult(
        _crontab('CRON_TZ=Europe/London\n30 1 * * * a'),
        _berlin,
        DateTime.utc(2026, 10, 24, 12),
      );
      expect(_runs(result).take(2), [
        (DateTime.utc(2026, 10, 25, 0, 30), 60, CronDst.overlap),
        (DateTime.utc(2026, 10, 26, 1, 30), 0, CronDst.none),
      ]);
    });

    test('a wildcard job runs by the clock in both passes', () {
      final result = cronResult(
        _crontab('CRON_TZ=Europe/London\n30 * * * * a'),
        _berlin,
        DateTime.utc(2026, 10, 24, 23),
      );
      expect(_runs(result), [
        (DateTime.utc(2026, 10, 24, 23, 30), 60, CronDst.none),
        (DateTime.utc(2026, 10, 25, 0, 30), 60, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 1, 30), 0, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 2, 30), 0, CronDst.none),
        (DateTime.utc(2026, 10, 25, 3, 30), 0, CronDst.none),
      ]);
    });

    test('the server\'s repeated hour runs no fixed-time job', () {
      // UTC has no transitions; Berlin repeats 01:00Z to 02:00Z.
      final result = cronResult(
        _crontab(
          'CRON_TZ=UTC\n30 1 * * * a\n30 0 * * * b\n30 0-23 * * * c\n'
          '30 * * * * d',
        ),
        _berlin,
        DateTime.utc(2026, 10, 25, 0, 15),
      );
      expect(_runs(result, 0).first, (
        DateTime.utc(2026, 10, 26, 1, 30),
        0,
        CronDst.none,
      ));
      // Within an hour of the server's transition, in its first pass.
      expect(_runs(result, 1).first, (
        DateTime.utc(2026, 10, 25, 0, 30),
        0,
        CronDst.nearTransition,
      ));
      expect(_runs(result, 2).take(3), [
        (DateTime.utc(2026, 10, 25, 0, 30), 0, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 2, 30), 0, CronDst.none),
        (DateTime.utc(2026, 10, 25, 3, 30), 0, CronDst.none),
      ]);
      expect(_runs(result, 3).take(3), [
        (DateTime.utc(2026, 10, 25, 0, 30), 0, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 1, 30), 0, CronDst.nearTransition),
        (DateTime.utc(2026, 10, 25, 2, 30), 0, CronDst.none),
      ]);
    });
  });

  test('a reading evaluates the runs of a bounded number of lines', () {
    final lines = List.filled(kCronLinesEvaluated + 1, '59 23 * * * a');
    final result = cronResult(
      _crontab(lines.join('\n')),
      _berlin,
      DateTime.utc(2026, 10, 14, 12),
    );
    final rows = result.jobs.cast<CronJobEntry>();
    expect(rows, hasLength(kCronLinesEvaluated + 1));
    expect(rows[kCronLinesEvaluated - 1].nextRuns, hasLength(5));
    expect(rows.last.runsUnknown, JobRunsUnknown.notEvaluated);
  });

  test('no probe answer yet means no server zone', () {
    expect(serverCronZone(null, DateTime.utc(2026)), (
      zone: null,
      zoneName: null,
      fallback: null,
    ));
  });
}

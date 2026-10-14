// Unified jobs list tests (03 §7.7, JOB-01, JOB-02): cron lines,
// periodic scripts and timers merge into one list; cron next runs come
// from the evaluator in the server zone or the line's CRON_TZ, with DST
// annotations; every missing run carries an enum reason.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

CronSnapshot _cron({
  String crontab = '',
  String etc = '',
  String cronD = '',
  String dirs = '',
}) => parseCron(
  '== crontab_meta ==\nrc=0\n'
  '== crontab ==\n$crontab\n'
  '== etc_crontab ==\n$etc\n'
  '== cron_d ==\n$cronD\n'
  '== cron_dirs ==\n$dirs\n',
  ParseContext.standard,
).value;

ServerZone _fixed(int hours, [String? name]) => ServerZone(
  offset: Duration(hours: hours),
  ianaName: name,
);

/// Europe/Berlin 2026 as a rule carrier: spring forward at
/// 2026-03-29T01:00Z, fall back at 2026-10-25T01:00Z.
ServerZone _berlin() => ServerZone(
  offset: const Duration(hours: 1),
  ianaName: 'Europe/Berlin',
  offsetAt: (utc) {
    final cest =
        !utc.isBefore(DateTime.utc(2026, 3, 29, 1)) &&
        utc.isBefore(DateTime.utc(2026, 10, 25, 1));
    return Duration(hours: cest ? 2 : 1);
  },
);

final _now = DateTime.utc(2026, 6, 1, 12);

List<JobEntry> _merge(
  CronSnapshot? cron, {
  TimersSnapshot? timers,
  DateTime? now,
  ServerZone? zone,
  CronZoneResolver? zoneFor,
  int runCount = 2,
}) => mergeJobs(
  cron: cron,
  timers: timers,
  nowUtc: now ?? _now,
  zone: zone ?? _fixed(0, 'Etc/UTC'),
  zoneFor: zoneFor,
  runCount: runCount,
);

CronJobEntry _only(List<JobEntry> jobs) =>
    jobs.whereType<CronJobEntry>().single;

void main() {
  group('merge', () {
    test('cron lines, periodic scripts, then timers, with stable ids', () {
      final timers = TimersSnapshot(
        timers: [
          const SystemdTimer(unit: 'logrotate.timer', nextUs: 1780315200000000),
        ],
      );
      final jobs = _merge(
        _cron(
          crontab: '5 * * * * a\n6 * * * * b',
          etc: '7 * * * * root c',
          cronD: 'x\t8 * * * * root d',
          dirs: 'daily logrotate',
        ),
        timers: timers,
      );
      expect(jobs.map((j) => j.id), [
        'cron|crontab|0',
        'cron|crontab|1',
        'cron|/etc/crontab|0',
        'cron|/etc/cron.d/x|0',
        'periodic|daily|logrotate',
        'timer|logrotate.timer',
      ]);
    });

    test('absent snapshots merge to an empty list', () {
      expect(_merge(null), isEmpty);
    });

    test('a nonpositive run count is a caller error', () {
      expect(() => _merge(null, runCount: 0), throwsArgumentError);
    });
  });

  group('cron next runs', () {
    test('a line runs in the server zone and honours the run count', () {
      final job = _only(
        _merge(
          _cron(crontab: '17 3 * * * backup'),
          zone: _fixed(2),
          runCount: 3,
        ),
      );
      expect(job.schedule!.text, '17 3 * * *');
      expect(job.runsUnknown, isNull);
      expect(job.nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 2, 1, 17),
        DateTime.utc(2026, 6, 3, 1, 17),
        DateTime.utc(2026, 6, 4, 1, 17),
      ]);
      expect(job.nextRunUtc, DateTime.utc(2026, 6, 2, 1, 17));
    });

    test('macros, steps and lists all evaluate', () {
      final jobs = _merge(
        _cron(crontab: '@hourly a\n*/20 * * * * b\n0 6,18 * * * c'),
      ).cast<CronJobEntry>();
      expect(jobs[0].nextRuns.first.atUtc, DateTime.utc(2026, 6, 1, 13));
      expect(jobs[1].nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 1, 12, 20),
        DateTime.utc(2026, 6, 1, 12, 40),
      ]);
      expect(jobs[2].nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 1, 18),
        DateTime.utc(2026, 6, 2, 6),
      ]);
    });

    test('@reboot, malformed and impossible schedules say why', () {
      final jobs = _merge(
        _cron(crontab: '@reboot a\n99 * * * * b\n0 0 30 2 * c'),
      ).cast<CronJobEntry>();
      expect(jobs[0].runsUnknown, JobRunsUnknown.reboot);
      expect(jobs[0].schedule!.macro, CronMacro.reboot);
      expect(jobs[1].runsUnknown, JobRunsUnknown.unparsed);
      expect(jobs[1].schedule, isNull);
      expect(jobs[1].schedules, isEmpty);
      expect(jobs[2].runsUnknown, JobRunsUnknown.noRunInHorizon);
      for (final job in jobs) {
        expect(job.nextRuns, isEmpty);
        expect(job.nextRunUtc, isNull);
      }
    });

    test('a spring-forward gap and a fall-back overlap are annotated', () {
      final gap = _only(
        _merge(
          _cron(crontab: '30 2 * * * a'),
          now: DateTime.utc(2026, 3, 28, 12),
          zone: _berlin(),
        ),
      );
      // Wall 02:30 does not exist on 2026-03-29; cronie runs it at the
      // jump, 01:00Z.
      expect(gap.nextRuns.first.atUtc, DateTime.utc(2026, 3, 29, 1));
      expect(gap.nextRuns.first.dst, CronDst.gap);
      expect(gap.nextRuns.last.dst, CronDst.none);

      final overlap = _only(
        _merge(
          _cron(crontab: '30 2 * * * a'),
          now: DateTime.utc(2026, 10, 24, 12),
          zone: _berlin(),
        ),
      );
      // Wall 02:30 occurs twice on 2026-10-25; the first pass is CEST.
      expect(overlap.nextRuns.first.atUtc, DateTime.utc(2026, 10, 25, 0, 30));
      expect(overlap.nextRuns.first.dst, CronDst.overlap);
      expect(overlap.nextRuns.first.offset, const Duration(hours: 2));
    });
  });

  group('CRON_TZ', () {
    test('the resolver supplies the zone, DST rules included', () {
      final job = _only(
        _merge(
          _cron(crontab: 'CRON_TZ=Europe/Berlin\n30 2 * * * a'),
          now: DateTime.utc(2026, 3, 28, 12),
          zoneFor: (name) => name == 'Europe/Berlin' ? _berlin() : null,
        ),
      );
      expect(job.schedule!.timeZone, 'Europe/Berlin');
      expect(job.nextRuns.first.dst, CronDst.gap);
      expect(job.nextRuns.last.atUtc, DateTime.utc(2026, 3, 30, 0, 30));
    });

    test('the server zone answers for its own name', () {
      final job = _only(
        _merge(
          _cron(crontab: 'CRON_TZ=Europe/Berlin\n30 2 * * * a'),
          zone: _fixed(2, 'Europe/Berlin'),
        ),
      );
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 6, 2, 0, 30));
    });

    test('UTC aliases need no resolver', () {
      final job = _only(
        _merge(_cron(crontab: 'CRON_TZ=UTC\n30 2 * * * a'), zone: _fixed(2)),
      );
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 6, 2, 2, 30));
      expect(job.nextRuns.first.offset, Duration.zero);
    });

    test('an unknown zone keeps the schedule but lists no runs', () {
      final job = _only(
        _merge(
          _cron(crontab: 'CRON_TZ=Asia/Tokyo\n30 2 * * * a'),
          zoneFor: (_) => null,
        ),
      );
      expect(job.schedule!.timeZone, 'Asia/Tokyo');
      expect(job.nextRuns, isEmpty);
      expect(job.runsUnknown, JobRunsUnknown.timeZoneUnresolved);
    });

    test('an empty CRON_TZ counts as unset', () {
      final job = _only(
        _merge(_cron(crontab: 'CRON_TZ=\n30 2 * * * a'), zone: _fixed(2)),
      );
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 6, 2, 0, 30));
    });

    test('CRON_TZ does not leak into the next cron.d file', () {
      final jobs = _merge(
        _cron(
          cronD:
              'a\tCRON_TZ=Asia/Tokyo\n'
              'a\t0 1 * * * root x\n'
              'b\t0 1 * * * root y',
        ),
      ).cast<CronJobEntry>();
      expect(jobs[0].runsUnknown, JobRunsUnknown.timeZoneUnresolved);
      expect(jobs[1].schedule!.timeZone, isNull);
      expect(jobs[1].nextRuns, isNotEmpty);
    });
  });

  group('periodic scripts', () {
    const debianEtc =
        '17 * * * * root cd / && run-parts --report /etc/cron.hourly\n'
        '25 6 * * * root test -x /usr/sbin/anacron || '
        'run-parts --report /etc/cron.daily';

    test('a direct run-parts line lends its schedule and runs', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'hourly 0anacron'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.directory, '/etc/cron.hourly');
      expect(script.driverIds, ['cron|/etc/crontab|0']);
      expect(script.schedule!.text, '17 * * * *');
      expect(script.nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 1, 12, 17),
        DateTime.utc(2026, 6, 1, 13, 17),
      ]);
      expect(script.nextRunUtc, DateTime.utc(2026, 6, 1, 12, 17));
    });

    test('a line that defers to anacron leaves the runs unknown', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'daily apt-compat'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, ['cron|/etc/crontab|1']);
      expect(script.schedule, isNull);
      expect(script.nextRuns, isEmpty);
      expect(script.runsUnknown, JobRunsUnknown.anacron);
    });

    test('a directory nothing runs has no driver', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'weekly man-db'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, isEmpty);
      expect(script.runsUnknown, JobRunsUnknown.noDriver);
    });

    test('every driver is listed and the first direct one wins', () {
      final jobs = _merge(
        _cron(
          etc: '01 * * * * root run-parts /etc/cron.hourly/',
          cronD: '0hourly\t02 * * * * root /usr/bin/run-parts /etc/cron.hourly',
          dirs: 'hourly 0yum-hourly.cron',
        ),
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, [
        'cron|/etc/crontab|0',
        'cron|/etc/cron.d/0hourly|0',
      ]);
      expect(script.schedule!.text, '01 * * * *');
    });

    test('a driver without runs passes its reason on', () {
      final jobs = _merge(
        _cron(
          etc: 'CRON_TZ=Asia/Tokyo\n0 3 * * * root run-parts /etc/cron.daily',
          dirs: 'daily x',
        ),
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.schedule!.timeZone, 'Asia/Tokyo');
      expect(script.runsUnknown, JobRunsUnknown.timeZoneUnresolved);
    });
  });

  group('timers', () {
    test('a timer keeps list-timers elapses and has no triggers yet', () {
      const timer = SystemdTimer(
        unit: 'fstrim.timer',
        activates: 'fstrim.service',
        nextUs: 1780315200000000,
      );
      final entry =
          _merge(null, timers: TimersSnapshot(timers: [timer])).single
              as TimerJobEntry;
      expect(entry.nextRunUtc, timer.nextUtc);
      expect(entry.schedules, isEmpty);
      expect(entry.randomizedDelay, isNull);
    });

    test('triggers and RandomizedDelaySec serialize when collected', () {
      final entry = TimerJobEntry(
        timer: const SystemdTimer(unit: 'apt-daily.timer'),
        schedules: [
          CalendarSchedule(normalized: '*-*-* 06,18:00:00'),
          const MonotonicSchedule(
            base: MonotonicBase.boot,
            span: Duration(minutes: 15),
          ),
        ],
        randomizedDelay: const Duration(hours: 12),
      );
      final json = entry.toJson();
      expect(json['kind'], 'timer');
      expect(json['randomizedDelayUs'], 43200000000);
      expect((json['schedules']! as List).map((s) => (s as Map)['type']), [
        'calendar',
        'monotonic',
      ]);
    });
  });
}

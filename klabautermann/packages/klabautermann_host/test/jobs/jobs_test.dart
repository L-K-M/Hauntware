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

    test('lines past the evaluation limit list no runs and say why', () {
      final jobs = mergeJobs(
        cron: _cron(
          crontab: '0 3 * * * a\n@reboot b\n0 4 * * * c\n0 5 * * * d',
        ),
        nowUtc: _now,
        zone: _fixed(0, 'Etc/UTC'),
        evaluateLimit: 2,
      ).cast<CronJobEntry>();
      // @reboot has nothing to evaluate, so it does not count.
      expect(jobs.map((j) => j.runsUnknown), [
        null,
        JobRunsUnknown.reboot,
        null,
        JobRunsUnknown.notEvaluated,
      ]);
      expect(jobs[3].schedule!.text, '0 5 * * *');
      expect(jobs[3].nextRuns, isEmpty);
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
          // The resolver's rules win over a same-named fixed server zone.
          zone: _fixed(1, 'Europe/Berlin'),
          zoneFor: (name) => name == 'Europe/Berlin' ? _berlin() : null,
        ),
      );
      expect(job.schedule!.timeZone, 'Europe/Berlin');
      // A CRON_TZ line misses its zone's gap (D58): 02:30 CEST next runs
      // on 2026-03-30, where the fixed +1 would give 01:30Z.
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 3, 30, 0, 30));
      expect(job.nextRuns.first.offset, const Duration(hours: 2));
    });

    test('the server zone\'s repeated hour runs no fixed-time line', () {
      // cronie runs only wildcard jobs while its own zone repeats an
      // hour, 01:00Z to 02:00Z here, whatever zone a line names.
      final jobs = _merge(
        _cron(crontab: 'CRON_TZ=UTC\n30 1 * * * a\n30 * * * * b'),
        now: DateTime.utc(2026, 10, 25, 0, 45),
        zone: _berlin(),
      ).cast<CronJobEntry>();
      expect(jobs[0].nextRuns.first.atUtc, DateTime.utc(2026, 10, 26, 1, 30));
      expect(jobs[1].nextRuns.first.atUtc, DateTime.utc(2026, 10, 25, 1, 30));
      expect(jobs[1].nextRuns.first.dst, CronDst.nearTransition);
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

    test('without a server zone only CRON_TZ lines have runs', () {
      final jobs = mergeJobs(
        cron: _cron(crontab: '30 2 * * * a\nCRON_TZ=UTC\n30 2 * * * b'),
        nowUtc: _now,
        zone: null,
      ).cast<CronJobEntry>();
      expect(jobs[0].nextRuns, isEmpty);
      expect(jobs[0].runsUnknown, JobRunsUnknown.serverZoneUnknown);
      expect(jobs[1].nextRuns.first.atUtc, DateTime.utc(2026, 6, 2, 2, 30));
    });

    test('an empty CRON_TZ names no zone', () {
      final job = _only(
        _merge(_cron(crontab: 'CRON_TZ=\n30 2 * * * a'), zone: _fixed(2)),
      );
      expect(job.schedule!.timeZone, isNull);
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 6, 2, 0, 30));
    });

    test('an empty CRON_TZ line misses the server zone\'s gap', () {
      // cronie keeps the empty value: the line reads the server's clock
      // but, as a CRON_TZ line, is never caught up (D58). A plain line
      // would run at the jump, 2026-03-29T01:00Z.
      final job = _only(
        _merge(
          _cron(crontab: 'CRON_TZ=\n30 2 * * * a'),
          now: DateTime.utc(2026, 3, 28, 12),
          zone: _berlin(),
        ),
      );
      expect(job.nextRuns.first.atUtc, DateTime.utc(2026, 3, 30, 0, 30));
      expect(job.nextRuns.first.dst, CronDst.none);
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

    test('a system macro line keeps its user, CRON_TZ and driver role', () {
      final jobs = _merge(
        _cron(
          etc: 'CRON_TZ=UTC\n@daily backup /opt/run.sh',
          cronD: 'p\t@daily root run-parts /etc/cron.daily',
          dirs: 'daily x',
        ),
        zone: _fixed(2),
      );
      final line = jobs.whereType<CronJobEntry>().first;
      expect((line.job.user, line.job.command), ('backup', '/opt/run.sh'));
      expect(line.schedule!.timeZone, 'UTC');
      expect(line.nextRuns.first.atUtc, DateTime.utc(2026, 6, 2));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, ['cron|/etc/cron.d/p|0']);
      expect(script.nextRuns.first.atUtc, DateTime.utc(2026, 6, 1, 22));
    });
  });

  group('periodic scripts', () {
    const debianEtc =
        '17 * * * * root cd / && run-parts --report /etc/cron.hourly\n'
        '25 6 * * * root test -x /usr/sbin/anacron || '
        'run-parts --report /etc/cron.daily';
    // Debian's anacron package ships this file and the 0anacron hooks.
    const anacronD =
        'anacron\t30 7 * * * root test -x /etc/init.d/anacron && '
        'systemctl start anacron';

    test('a direct run-parts line lends its schedule and runs', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'hourly 0anacron'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.directory, '/etc/cron.hourly');
      expect(script.driverIds, ['cron|/etc/crontab|0']);
      expect(script.schedules.single.text, '17 * * * *');
      expect(script.nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 1, 12, 17),
        DateTime.utc(2026, 6, 1, 13, 17),
      ]);
      expect(script.nextRunUtc, DateTime.utc(2026, 6, 1, 12, 17));
    });

    test('a line that defers to anacron leaves the runs unknown', () {
      final jobs = _merge(
        _cron(etc: debianEtc, cronD: anacronD, dirs: 'daily apt-compat'),
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, ['cron|/etc/crontab|1']);
      expect(script.schedules, isEmpty);
      expect(script.nextRuns, isEmpty);
      expect(script.runsUnknown, JobRunsUnknown.anacron);
    });

    test('without anacron installed a guarded line runs the directory', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'daily apt-compat'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.schedules.single.text, '25 6 * * *');
      expect(script.nextRunUtc, DateTime.utc(2026, 6, 2, 6, 25));
    });

    test('cronie-anacron runs daily, weekly and monthly from no line', () {
      // RHEL 8 and later: /etc/crontab holds no run-parts line, and
      // /etc/cron.hourly/0anacron starts anacron.
      final jobs = _merge(
        _cron(
          cronD: '0hourly\t01 * * * * root run-parts /etc/cron.hourly',
          dirs: 'hourly 0anacron\ndaily logrotate\nmonthly x',
        ),
      ).whereType<PeriodicJobEntry>().toList();
      expect(jobs[0].nextRuns, isNotEmpty);
      expect(jobs[1].runsUnknown, JobRunsUnknown.anacron);
      expect(jobs[2].runsUnknown, JobRunsUnknown.anacron);
    });

    test('a directory nothing runs has no driver', () {
      final jobs = _merge(_cron(etc: debianEtc, dirs: 'weekly man-db'));
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, isEmpty);
      expect(script.runsUnknown, JobRunsUnknown.noDriver);
    });

    test('direct drivers merge their schedules and runs', () {
      final jobs = _merge(
        _cron(
          etc: '0 3 * * * root run-parts /etc/cron.daily/',
          cronD: 'extra\t0 1 * * * root /usr/bin/run-parts /etc/cron.daily',
          dirs: 'daily logrotate',
        ),
        runCount: 3,
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.driverIds, [
        'cron|/etc/crontab|0',
        'cron|/etc/cron.d/extra|0',
      ]);
      expect(script.schedules.map((s) => s.text), ['0 3 * * *', '0 1 * * *']);
      expect(script.nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 2, 1),
        DateTime.utc(2026, 6, 2, 3),
        DateTime.utc(2026, 6, 3, 1),
      ]);
    });

    test('a driver without runs yields to one with runs', () {
      final jobs = _merge(
        _cron(
          etc:
              '@reboot root run-parts /etc/cron.daily\n'
              '0 3 * * * root run-parts /etc/cron.daily\n'
              '0 3 * * * root run-parts /etc/cron.daily',
          dirs: 'daily x',
        ),
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.schedules, hasLength(3));
      expect(script.runsUnknown, isNull);
      // Two drivers firing at the same instant list one run.
      expect(script.nextRuns.map((r) => r.atUtc), [
        DateTime.utc(2026, 6, 2, 3),
        DateTime.utc(2026, 6, 3, 3),
      ]);
    });

    test('the scripts of one directory share its drivers and runs', () {
      // Matching every script against every line was quadratic: 4,000
      // lines by 4,000 scripts took 37 s and copied each list per row.
      final jobs = _merge(
        _cron(
          etc: '0 3 * * * root run-parts /etc/cron.daily',
          dirs: 'daily a\ndaily b\nhourly c',
        ),
      ).whereType<PeriodicJobEntry>().toList();
      expect(jobs[0].driverIds, ['cron|/etc/crontab|0']);
      expect(jobs[1].driverIds, same(jobs[0].driverIds));
      expect(jobs[1].schedules, same(jobs[0].schedules));
      expect(jobs[1].nextRuns, same(jobs[0].nextRuns));
      expect(jobs[2].runsUnknown, JobRunsUnknown.noDriver);
    });

    test('a driver without runs passes its reason on', () {
      final jobs = _merge(
        _cron(
          etc: 'CRON_TZ=Asia/Tokyo\n0 3 * * * root run-parts /etc/cron.daily',
          dirs: 'daily x',
        ),
      );
      final script = jobs.whereType<PeriodicJobEntry>().single;
      expect(script.schedules.single.timeZone, 'Asia/Tokyo');
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
      // Not collected is null, distinct from a timer without triggers.
      expect(entry.triggers, isNull);
      expect(entry.schedules, isEmpty);
      expect(entry.toJson()['triggers'], isNull);
      expect(entry.randomizedDelay, isNull);
    });

    test('triggers and RandomizedDelaySec serialize when collected', () {
      final entry = TimerJobEntry(
        timer: const SystemdTimer(unit: 'apt-daily.timer'),
        triggers: [
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
      expect((json['triggers']! as List).map((s) => (s as Map)['type']), [
        'calendar',
        'monotonic',
      ]);
    });

    group('detail (D57)', () {
      final detail = TimerDetail(
        calendar: ['*-*-* 06,18:00:00', 'Mon *-*-* 00:00:00'],
        monotonic: [
          const MonotonicSchedule(
            base: MonotonicBase.boot,
            span: Duration(minutes: 15),
          ),
        ],
        randomizedDelay: const Duration(hours: 12),
      );

      test('one systemd-analyze read per calendar expression', () {
        final reads = timerCalendarCommands(detail, runCount: 5);
        expect(reads.keys, detail.calendar);
        expect(
          reads['Mon *-*-* 00:00:00'],
          HostCommands.onCalendar('Mon *-*-* 00:00:00', iterations: 5),
        );
      });

      test('below systemd 242 a read asks for one run', () {
        final reads = timerCalendarCommands(
          detail,
          runCount: 5,
          systemdMajor: 239,
        );
        expect(
          reads.values.map((argv) => argv[2]),
          everyElement('(unset TZ; systemd-analyze calendar -- "\$1")'),
        );
      });

      test('an expression the builder refuses gets no read', () {
        final hostile = TimerDetail(calendar: ['daily\nreboot', 'x' * 600]);
        expect(timerCalendarCommands(hostile, runCount: 2), isEmpty);
      });

      test('triggers take their calendar results, then the monotonic', () {
        final result = parseOnCalendar('''
  Original form: *-*-* 06,18:00:00
Normalized form: *-*-* 06,18:00:00
    Next elapse: Thu 2026-10-15 18:00:00 UTC
''').value;
        final entry = TimerJobEntry(
          timer: const SystemdTimer(unit: 'apt-daily.timer'),
        ).withDetail(detail, calendars: {'*-*-* 06,18:00:00': result});
        expect(entry.randomizedDelay, const Duration(hours: 12));
        expect(entry.triggers!.map((t) => t.toJson()), [
          {
            'type': 'calendar',
            'normalized': '*-*-* 06,18:00:00',
            'elapses': [
              {
                'text': 'Thu 2026-10-15 18:00:00 UTC',
                'atUtc': '2026-10-15T18:00:00.000Z',
                'fromNow': null,
              },
            ],
          },
          // Not read yet: the expression, with elapses unknown.
          {
            'type': 'calendar',
            'normalized': 'Mon *-*-* 00:00:00',
            'elapses': null,
          },
          {'type': 'monotonic', 'base': 'boot', 'spanUs': 900000000},
        ]);
      });

      test('a read without triggers leaves triggers and delay unknown', () {
        // What `systemctl show` prints for a unit that is no longer
        // loaded; a loaded timer without these triggers has only
        // OnClockChange= or OnTimezoneChange=.
        final empty = parseTimerDetail(
          'RandomizedDelayUSec=0\n',
          ParseContext.standard,
        ).value;
        final entry = TimerJobEntry(
          timer: const SystemdTimer(unit: 'gone.timer'),
        ).withDetail(empty);
        expect(entry.triggers, isNull);
        expect(entry.randomizedDelay, isNull);
      });

      test('a rejected expression keeps its text without elapses', () {
        final rejected = parseOnCalendar('Failed to parse: x\n').value;
        final entry = TimerJobEntry(
          timer: const SystemdTimer(unit: 'x.timer'),
        ).withDetail(TimerDetail(calendar: ['x']), calendars: {'x': rejected});
        final trigger = entry.triggers!.single as CalendarSchedule;
        expect(trigger.normalized, 'x');
        expect(trigger.elapses, isNull);
      });
    });
  });

  test('rows carry the shown line, but run-parts reads the real one', () {
    final cron = _cron(
      etc: '17 * * * * root run-parts /etc/cron.hourly\n',
      dirs: 'hourly logrotate',
    );
    final jobs = mergeJobs(
      cron: cron,
      nowUtc: _now,
      zone: _fixed(0, 'Etc/UTC'),
      shownJob: (job) => CronJob(
        source: job.source,
        schedule: job.schedule,
        command: 'shown',
        raw: 'shown',
        expression: job.expression,
        user: job.user,
      ),
    );
    final line = _only(jobs);
    expect(line.job.command, 'shown');
    expect(line.nextRuns, isNotEmpty);
    final script = jobs.whereType<PeriodicJobEntry>().single;
    expect(script.driverIds, [line.id]);
    expect(script.nextRuns, isNotEmpty);
  });
}

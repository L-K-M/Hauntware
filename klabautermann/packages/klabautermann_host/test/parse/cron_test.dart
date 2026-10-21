// `cron` parser tests (03 §6.4, §7.7): the user's `crontab -l`, the
// system crontabs with their user column, `/etc/cron.d/*` with per-file
// `CRON_TZ` scoping, and the `cron.<period>` directory names.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

/// A `cron` payload with a present own crontab and these blocks.
String _payload({String crontab = '', String etc = '', String cronD = ''}) =>
    '== crontab_meta ==\nrc=0\n'
    '== crontab ==\n$crontab\n'
    '== etc_crontab ==\n$etc\n'
    '== cron_d ==\n$cronD\n'
    '== cron_dirs ==\n';

/// Each job's source, schedule, user and command.
List<(String, String, String?, String)> _shapes(CronSnapshot s) => [
  for (final j in s.jobs) (j.source, j.schedule, j.user, j.command),
];

void main() {
  test('crontab -l jobs parse without a user field', () {
    final raw = [
      '== crontab_meta ==',
      'rc=0',
      '== crontab ==',
      '# m h dom mon dow command',
      'CRON_TZ=Europe/Berlin',
      '17 3 * * * /usr/local/bin/backup --full',
      '@daily /usr/bin/find /tmp -mindepth 1 -delete',
      '== etc_crontab ==',
      '== cron_d ==',
      '== cron_dirs ==',
    ].join('\n');

    final r = parseCron(raw, _ctx);
    expect(r.value.ownCrontabPresent, isTrue);
    expect(r.value.jobs, hasLength(2));
    final daily = r.value.jobs.first;
    expect(daily.source, 'crontab');
    expect(daily.user, isNull);
    expect(daily.cronTz, 'Europe/Berlin');
    expect(daily.expression, isNotNull);
    expect(daily.expression!.minutes, {17});
    expect(daily.expression!.hours, {3});
    expect(r.value.jobs.last.schedule, '@daily');
    expect(r.value.jobs.last.command, '/usr/bin/find /tmp -mindepth 1 -delete');
    expect(r.value.jobs.last.expression!.hours, {0});
  });

  test('a BusyBox crontab -l has no user column', () {
    // BusyBox crond reads /etc/crontabs/<user> and has no /etc/crontab;
    // Alpine's default crontab separates fields with tabs.
    final raw = [
      '== crontab_meta ==',
      'rc=0',
      '== crontab ==',
      '# min\thour\tday\tmonth\tweekday\tcommand',
      '*/15\t*\t*\t*\t*\trun-parts /etc/periodic/15min',
      '0\t3\t*\t*\t6\trun-parts /etc/periodic/weekly',
      '== etc_crontab ==',
      '== cron_d ==',
      '== cron_dirs ==',
    ].join('\n');

    final r = parseCron(raw, _ctx);
    expect(r.warnings, isEmpty);
    expect(r.value.jobs.map((j) => (j.source, j.user, j.command)), [
      ('crontab', null, 'run-parts /etc/periodic/15min'),
      ('crontab', null, 'run-parts /etc/periodic/weekly'),
    ]);
    expect(r.value.jobs.first.expression!.minutes, {0, 15, 30, 45});
    expect(r.value.jobs.last.expression!.weekDays, {6});
  });

  test('/etc/crontab carries the user column', () {
    final raw = [
      '== crontab_meta ==',
      'rc=1',
      '== crontab ==',
      'no crontab for root',
      '== etc_crontab ==',
      'SHELL=/bin/sh',
      '17 *\t* * *\troot\tcd / && run-parts --report /etc/cron.hourly',
      '== cron_d ==',
      '== cron_dirs ==',
    ].join('\n');

    final r = parseCron(raw, _ctx);
    expect(r.value.ownCrontabPresent, isFalse);
    final job = r.value.jobs.single;
    expect(job.source, '/etc/crontab');
    expect(job.user, 'root');
    expect(job.schedule, '17 * * * *');
    expect(job.command, 'cd / && run-parts --report /etc/cron.hourly');
    expect(r.warnings, isEmpty);
  });

  test('cron.d lines keep the file prefix and scope CRON_TZ per file', () {
    final raw = [
      '== crontab_meta ==',
      'rc=0',
      '== crontab ==',
      '== etc_crontab ==',
      '== cron_d ==',
      'a\tCRON_TZ=UTC',
      'a\t0 1 * * *\troot\t/usr/bin/a',
      'b\t30 7 * * *\troot\t/usr/bin/b',
      '== cron_dirs ==',
    ].join('\n');

    final r = parseCron(raw, _ctx);
    expect(r.value.jobs, hasLength(2));
    final a = r.value.jobs.firstWhere((j) => j.command == '/usr/bin/a');
    final b = r.value.jobs.firstWhere((j) => j.command == '/usr/bin/b');
    expect(a.source, '/etc/cron.d/a');
    expect(a.cronTz, 'UTC');
    // CRON_TZ does not cross files (03 §7.7).
    expect(b.cronTz, isNull);
    expect(b.user, 'root');
  });

  test('cron.<period> directory entries land per period', () {
    final raw = [
      '== crontab_meta ==',
      'tool=missing',
      '== crontab ==',
      '== etc_crontab ==',
      '== cron_d ==',
      '== cron_dirs ==',
      'hourly 0anacron',
      'hourly cleanup',
      'daily apt-compat',
      'weekly man-db',
      'monthly mdadm',
    ].join('\n');

    final r = parseCron(raw, _ctx);
    expect(r.value.ownCrontabPresent, isNull);
    expect(r.value.dirEntries, hasLength(5));
    expect(r.value.dirEntries.first.period, CronPeriod.hourly);
    expect(r.value.dirEntries.first.name, '0anacron');
    expect(r.value.dirEntries.map((e) => e.period).toSet(), {
      CronPeriod.hourly,
      CronPeriod.daily,
      CronPeriod.weekly,
      CronPeriod.monthly,
    });
  });

  // cron reads a system table's user field after an `@` macro as after
  // five fields, and a user crontab has none [R: cronie `entry.c`
  // `load_entry`].
  group('@ macros', () {
    test('a system table reads the user field after every macro', () {
      for (final macro in CronMacro.values) {
        final r = parseCron(
          _payload(
            etc: '@${macro.name} root /usr/bin/x --flag',
            cronD: 'f\t@${macro.name}\tbackup\t/opt/run.sh',
          ),
          _ctx,
        );
        expect(r.warnings, isEmpty, reason: macro.name);
        expect(_shapes(r.value), [
          ('/etc/crontab', '@${macro.name}', 'root', '/usr/bin/x --flag'),
          ('/etc/cron.d/f', '@${macro.name}', 'backup', '/opt/run.sh'),
        ], reason: macro.name);
        expect(r.value.jobs.map((j) => j.expression?.macro), [macro, macro]);
      }
    });

    test('a user crontab reads no user field after a macro', () {
      for (final macro in CronMacro.values) {
        final r = parseCron(
          _payload(crontab: '@${macro.name} /usr/bin/x --flag'),
          _ctx,
        );
        expect(r.warnings, isEmpty, reason: macro.name);
        expect(_shapes(r.value), [
          ('crontab', '@${macro.name}', null, '/usr/bin/x --flag'),
        ], reason: macro.name);
      }
    });

    test('a system macro line that ends at its user field is no job', () {
      // cron reads the first word after the macro as the user without
      // checking that it exists (cronie loads such a line for an unknown
      // user), then skips a line with nothing after it.
      final r = parseCron(
        _payload(
          etc: '@reboot /usr/bin/x\n@daily /opt/run.sh nightly\n@weekly',
          cronD: 'f\t@hourly root  ',
        ),
        _ctx,
      );
      expect(_shapes(r.value), [
        ('/etc/crontab', '@daily', '/opt/run.sh', 'nightly'),
      ]);
      expect(r.warnings, hasLength(3));
    });

    test('an unknown macro keeps the system shape and warns', () {
      final r = parseCron(_payload(etc: '@every root /usr/bin/x'), _ctx);
      expect(_shapes(r.value), [
        ('/etc/crontab', '@every', 'root', '/usr/bin/x'),
      ]);
      expect(r.value.jobs.single.expression, isNull);
      expect(r.warnings, [contains('unparseable')]);
    });
  });

  test('a command keeps its blanks, past those that end the fields', () {
    final r = parseCron(
      _payload(
        crontab: "0 3 * * * echo 'a  b'",
        etc: "@daily\troot\techo a\tb\n0 3 * * * root  echo  'x  y'",
      ),
      _ctx,
    );
    expect(r.value.jobs.map((j) => j.command), [
      "echo 'a  b'",
      'echo a\tb',
      "echo  'x  y'",
    ]);
  });

  test('a malformed schedule warns but the job is kept', () {
    final raw = [
      '== crontab_meta ==',
      'rc=0',
      '== crontab ==',
      '99 0 * * * /usr/bin/bad',
      '== etc_crontab ==',
      '== cron_d ==',
      '== cron_dirs ==',
    ].join('\n');
    final r = parseCron(raw, _ctx);
    expect(r.value.jobs.single.expression, isNull);
    expect(r.warnings, contains(contains('unparseable')));
  });

  test('another user\'s crontab is a user table that names its user', () {
    final r = parseUserCrontab(
      '# m h dom mon dow command\n'
      'MAILTO=""\n'
      'CRON_TZ=Europe/Berlin\n'
      '*/5 * * * * /usr/local/bin/sync --quiet\n'
      '@reboot\n',
      user: 'alice',
    );
    final job = r.value.single;
    expect(job.source, 'crontab -u alice');
    expect(job.source, userCrontabSource('alice'));
    expect(job.user, 'alice');
    expect(job.schedule, '*/5 * * * *');
    expect(job.command, '/usr/local/bin/sync --quiet');
    expect(job.cronTz, 'Europe/Berlin');
    expect(r.warnings, [contains('short line')]);
  });

  test('a paused job is a paused row holding its line, and a managed '
      "block's jobs name their manager (JOB-07, JOB-09)", () {
    final r = parseCron(
      _payload(
        crontab:
            '${kCrontabPauseMarker}2026-10-21T03:00:00Z 0 3 * * * /bin/backup\n'
            '$kCrontabPauseMarker'
            '2026-10-21T03:00:00Z MAILTO=x\n'
            '# dokku cron jobs\n'
            '*/5 * * * * dokku run app task',
        cronD: 'coolify\t0 4 * * * root /opt/coolify/prune',
      ),
      _ctx,
    );

    final [paused, managed, cronD] = r.value.jobs;
    expect(paused.paused, isTrue);
    expect(paused.command, '/bin/backup');
    expect(paused.raw, startsWith(kCrontabPauseMarker));
    expect(paused.managedBy, isNull);
    expect(managed.paused, isFalse);
    expect(managed.managedBy, CrontabManager.dokku);
    expect(cronD.managedBy, CrontabManager.coolify);
    expect(cronD.toJson()['managedBy'], 'coolify');
    expect(paused.toJson()['paused'], isTrue);
  });

  group('one source read alone (JOB-19)', () {
    test('a user table carries its user and source', () {
      final jobs = parseCrontabText(
        '# nightly\nMAILTO=ops\n0 3 * * * /usr/local/bin/backup %daily\n',
        source: userCrontabSource('alice'),
        systemTable: false,
        user: 'alice',
      );
      final job = jobs.single;
      expect(job.user, 'alice');
      expect(job.source, 'crontab -u alice');
      expect(job.command, '/usr/local/bin/backup %daily');
    });

    test("a system table reads each line's user", () {
      final jobs = parseCrontabText(
        '*/5 * * * * www-data php /srv/app/cron.php\n',
        source: '/etc/cron.d/app',
        systemTable: true,
      );
      expect(jobs.single.user, 'www-data');
      expect(jobs.single.command, 'php /srv/app/cron.php');
    });

    test("dokku's own crontab is Dokku's, read as another user's", () {
      final jobs = parseUserCrontab(
        '0 3 * * * /usr/bin/dokku cleanup\n',
        user: 'dokku',
      ).value;
      expect(jobs.single.managedBy, CrontabManager.dokku);
      expect(jobs.single.user, 'dokku');
    });
  });
}

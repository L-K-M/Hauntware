// Job history tests (03 §7.7 v1): anacron's table and stamps (JOB-04), a
// timer's last run and cron's logged runs (JOB-05), plus their builders.
// The samples follow the tools' output under `TZ=UTC`.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('anacron', () {
    test('jobs carry their period, delay and last run', () {
      final r = parseAnacron(
        '# /etc/anacrontab: configuration file for anacron\n'
        'SHELL=/bin/sh\n'
        'HOME=/root\n'
        '\n'
        '1\t5\tcron.daily\trun-parts --report /etc/cron.daily\n'
        '7\t10\tcron.weekly\trun-parts --report /etc/cron.weekly\n'
        '@monthly\t15\tcron.monthly\trun-parts --report /etc/cron.monthly\n'
        'bogus line\n'
        '\n'
        '$kAnacronStampsMarker\n'
        'cron.daily 20261020\n'
        'cron.weekly ?\n'
        'cron.monthly 20261001\n',
      );
      expect(r.value.map((j) => j.toJson()), [
        {
          'period': '1d',
          'delayMinutes': 5,
          'identifier': 'cron.daily',
          'command': 'run-parts --report /etc/cron.daily',
          'lastRun': '2026-10-20T00:00:00.000Z',
        },
        {
          'period': '7d',
          'delayMinutes': 10,
          'identifier': 'cron.weekly',
          'command': 'run-parts --report /etc/cron.weekly',
          'lastRun': null,
        },
        {
          'period': '@monthly',
          'delayMinutes': 15,
          'identifier': 'cron.monthly',
          'command': 'run-parts --report /etc/cron.monthly',
          'lastRun': '2026-10-01T00:00:00.000Z',
        },
      ]);
      expect(r.warnings, ['anacron: line "bogus line"']);
    });

    test('@weekly and @daily read as seven and one days', () {
      final r = parseAnacron(
        '@weekly 3 w true\n@daily 0 d true\n$kAnacronStampsMarker\n',
      );
      expect(r.value.map((j) => j.period), [
        const AnacronPeriod.days(7),
        const AnacronPeriod.days(1),
      ]);
    });

    test('the builder runs a constant script', () {
      final argv = HostCommands.anacron();
      expect(argv.take(2), ['sh', '-c']);
      expect(argv[2], contains('/var/spool/anacron/*'));
      expect(argv[2], contains('exit $kAnacronMissing'));
    });
  });

  group('timer last run', () {
    test('the trigger comes from the timer, the result from the service', () {
      final r = parseTimerLastRun(
        'Id=backup.timer\n'
        'LastTriggerUSec=Tue 2026-10-20 03:00:00 UTC\n'
        'Result=success\n'
        'ExecMainStatus=\n'
        'ExecMainExitTimestamp=\n'
        '\n'
        'Id=backup.service\n'
        'LastTriggerUSec=\n'
        'Result=exit-code\n'
        'ExecMainStatus=2\n'
        'ExecMainExitTimestamp=Tue 2026-10-20 03:00:07 UTC\n',
      );
      expect(r.warnings, isEmpty);
      expect(r.value.toJson(), {
        'lastTrigger': '2026-10-20T03:00:00.000Z',
        'result': 'exit-code',
        'exitStatus': 2,
        'finished': '2026-10-20T03:00:07.000Z',
      });
    });

    test('a timer that never triggered reports nothing', () {
      final r = parseTimerLastRun(
        'Id=new.timer\nLastTriggerUSec=n/a\n\n'
        'Id=new.service\nResult=success\nExecMainStatus=0\n'
        'ExecMainExitTimestamp=\n',
      );
      expect(r.value.lastTrigger, isNull);
      expect(r.value.finished, isNull);
      expect(r.value.result, 'success');
    });

    test('the builder validates both units', () {
      expect(HostCommands.timerLastRun('backup.timer', 'backup.service'), [
        'systemctl',
        'show',
        '--property=Id,LastTriggerUSec,Result,ExecMainStatus,'
            'ExecMainExitTimestamp',
        '--',
        'backup.timer',
        'backup.service',
      ]);
      expect(
        () => HostCommands.timerLastRun('backup.service', 'backup.service'),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.timerLastRun('backup.timer', 'x; id'),
        throwsA(isA<HostCommandError>()),
      );
    });
  });

  group('cron runs', () {
    JournalEntry entry(String id, String message, int seconds) => JournalEntry({
      'SYSLOG_IDENTIFIER': id,
      'MESSAGE': message,
      '__REALTIME_TIMESTAMP': '${seconds * 1000000}',
    });

    test('CMD lines from cron and cronie, and BusyBox crond lines', () {
      final runs = parseCronRuns([
        entry(
          'CRON',
          '(root) CMD (cd / && run-parts --report /etc/cron.hourly)',
          1760947200,
        ),
        entry(
          'CRON',
          'pam_unix(cron:session): session opened for user root',
          1760947200,
        ),
        entry('CROND', '(alice) CMD (/home/alice/bin/sync)', 1760947260),
        entry('crond', 'USER bob pid 4242 cmd /usr/bin/backup', 1760947320),
        entry('CRON', '(root) END (run-parts /etc/cron.hourly)', 1760947201),
        entry('sshd', '(root) CMD (not cron)', 1760947400),
      ]);
      expect(runs.map((r) => r.toJson()), [
        {
          'at': '2025-10-20T08:00:00.000Z',
          'user': 'root',
          'command': 'cd / && run-parts --report /etc/cron.hourly',
        },
        {
          'at': '2025-10-20T08:01:00.000Z',
          'user': 'alice',
          'command': '/home/alice/bin/sync',
        },
        {
          'at': '2025-10-20T08:02:00.000Z',
          'user': 'bob',
          'command': '/usr/bin/backup',
        },
      ]);
    });

    test('the builder reads every cron identifier, newest first', () {
      expect(HostCommands.cronRuns(lines: 50), [
        'journalctl',
        '-o',
        'json',
        '--no-pager',
        '-t',
        'CRON',
        '-t',
        'CROND',
        '-t',
        'crond',
        '-n',
        '50',
        '-r',
      ]);
    });
  });
}

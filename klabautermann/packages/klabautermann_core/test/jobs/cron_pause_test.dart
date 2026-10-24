// Pause and Resume on a cron line (03 §7.7, JOB-07): which crontabs they
// rewrite, and the text they write, from rows the real parser built.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show CronJob, CrontabManager, kCrontabPauseMarker, parseCrontabText;
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 10, 21, 8, 30);

const _crontab =
    '# nightly jobs\n'
    'MAILTO=ops@example.com\n'
    '0 3 * * * /usr/local/bin/backup --all\n'
    '*/5 * * * * /usr/local/bin/poll\n';

List<CronJob> _own(String text) =>
    parseCrontabText(text, source: kOwnCrontabSource, systemTable: false);

void main() {
  group('cronPauseTarget', () {
    test("names the login user's crontab and another user's", () {
      expect(cronPauseTarget(_own(_crontab).first), const CrontabTarget());
      final theirs = parseCrontabText(
        _crontab,
        source: userCrontabSource('deploy'),
        systemTable: false,
        user: 'deploy',
      ).first;
      expect(cronPauseTarget(theirs), const CrontabTarget(user: 'deploy'));
    });

    test('leaves system tables and managed lines alone', () {
      final system = parseCrontabText(
        '0 3 * * * root /usr/local/bin/backup\n',
        source: '/etc/crontab',
        systemTable: true,
      ).single;
      expect(cronPauseTarget(system), isNull);

      final job = _own(_crontab).first;
      final managed = CronJob(
        source: job.source,
        schedule: job.schedule,
        command: job.command,
        raw: job.raw,
        managedBy: CrontabManager.values.first,
      );
      expect(cronPauseTarget(managed), isNull);
    });

    test("refuses a user source that does not name the job's user", () {
      final job = CronJob(
        source: userCrontabSource('deploy'),
        schedule: '0 3 * * *',
        command: 'true',
        raw: '0 3 * * * true',
        user: 'root',
      );
      expect(cronPauseTarget(job), isNull);
    });
  });

  group('togglePausedCronJob', () {
    test('pauses only the line, keeping comments and environment', () {
      final backup = _own(_crontab).first;
      final paused = togglePausedCronJob(_crontab, backup, at: _at);
      expect(
        paused,
        '# nightly jobs\n'
        'MAILTO=ops@example.com\n'
        '${kCrontabPauseMarker}2026-10-21T08:30:00Z '
        '0 3 * * * /usr/local/bin/backup --all\n'
        '*/5 * * * * /usr/local/bin/poll\n',
      );

      // The parser reads the paused line back as paused, and Resume
      // restores the crontab byte for byte.
      final row = _own(paused!).firstWhere((job) => job.paused);
      expect(row.command, '/usr/local/bin/backup --all');
      expect(togglePausedCronJob(paused, row, at: _at), _crontab);
    });

    test('finds the line in a CRLF crontab', () {
      final crlf = _crontab.replaceAll('\n', '\r\n');
      final poll = _own(crlf).last;
      final paused = togglePausedCronJob(crlf, poll, at: _at)!;
      expect(
        paused.split('\n')[3],
        '${kCrontabPauseMarker}2026-10-21T08:30:00Z '
        '*/5 * * * * /usr/local/bin/poll\r',
      );
    });

    test('answers null for a line the crontab no longer holds', () {
      final backup = _own(_crontab).first;
      const edited = '0 4 * * * /usr/local/bin/backup --all\n';
      expect(togglePausedCronJob(edited, backup, at: _at), isNull);

      // Paused elsewhere since the read: Pause finds no job line.
      final paused = togglePausedCronJob(_crontab, backup, at: _at)!;
      expect(togglePausedCronJob(paused, backup, at: _at), isNull);
    });
  });
}

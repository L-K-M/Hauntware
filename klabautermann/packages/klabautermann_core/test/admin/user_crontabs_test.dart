// JOB-03's read of other users' crontabs (M4 plan M14, E14b) and the
// masking of every cron command before it crosses (03 §8.9): the spool's
// valid names are read through the elevation executor, a removed crontab
// is left out, an unreadable one is named, and each failure is typed.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show ParseContext, kCrontabSpoolDenied, kCrontabSpoolMissing, parseCron;
import 'package:klabautermann_core/src/admin/user_crontabs.dart';
import 'package:klabautermann_core/src/sampling/sample_results.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';
final _now = DateTime.utc(2026, 10, 18, 12);

/// Answers each command with the first of [answers] whose key it
/// contains, and records it.
final class _Link extends TestLinkBase {
  _Link(this.answers);

  final Map<String, RemoteCommandResult> answers;
  final commands = <String>[];
  Object? failure;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?) throw error;
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return const RemoteCommandResult(exitCode: 1, stderr: 'unexpected');
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

Future<UserCrontabs> _read(
  _Link link, {
  ElevationProbe probe = const ElevationProbe(isRoot: true),
}) => readUserCrontabs(
  _server,
  requestId: 'r-1',
  session: AdminSession.test(ElevatedExecutor(link, probe), null),
  profile: HostProfile(zoneOffset: '+0000', timezone: 'Etc/UTC'),
  now: _now,
);

void main() {
  test('reads each valid user in the spool, commands masked', () async {
    final link = _Link({
      'klabautermann-spool': _out(
        '/var/spool/cron/crontabs\nalice\nbob\ncarol\ntmp.Xa91\n',
      ),
      "'alice'": _out(
        '# backups\n'
        '0 3 * * * mysqldump -psecretpw app > /srv/app.sql\n'
        '@hourly curl -s https://ops:hunter2@example.com/ping\n',
      ),
      "'bob'": const RemoteCommandResult(
        exitCode: 1,
        stderr: 'no crontab for bob\n',
      ),
      "'carol'": const RemoteCommandResult(
        exitCode: 1,
        stderr: 'crontab: Permission denied\n',
      ),
    });

    final read = await _read(link);
    expect(read.failure, isNull);
    expect(read.requestId, 'r-1');
    expect(read.directory, '/var/spool/cron/crontabs');
    expect(read.skipped, 1, reason: 'tmp.Xa91 is not a user name');
    expect(read.unreadable, ['carol']);
    expect(read.notRead, 0);
    expect(read.zoneName, 'Etc/UTC');

    final rows = read.jobs.cast<CronJobEntry>();
    expect([for (final r in rows) r.job.user], ['alice', 'alice']);
    expect([
      for (final r in rows) r.job.source,
    ], everyElement('crontab -u alice'));
    final shown = [for (final r in rows) '${r.job.command} ${r.job.raw}'];
    expect(shown.join(), isNot(contains('secretpw')));
    expect(shown.join(), isNot(contains('hunter2')));
    expect(rows.first.job.command, startsWith('mysqldump -p'));
    expect(rows.first.nextRuns.first.atUtc, DateTime.utc(2026, 10, 19, 3));
    expect(link.commands, hasLength(4), reason: 'tmp.Xa91 is never read');
  });

  test('reads at most kUserCrontabsRead users and counts the rest', () async {
    final users = [for (var i = 0; i < kUserCrontabsRead + 3; i++) 'u$i'];
    final link = _Link({
      'klabautermann-spool': _out('/var/spool/cron\n${users.join('\n')}\n'),
      "'crontab'": _out(''),
    });
    final read = await _read(link);
    expect(read.notRead, 3);
    expect(link.commands, hasLength(kUserCrontabsRead + 1));
  });

  group('typed failures', () {
    final cases = <String, (RemoteCommandResult, UserCrontabsFailure)>{
      'no spool': (
        const RemoteCommandResult(exitCode: kCrontabSpoolMissing),
        UserCrontabsFailure.noSpool,
      ),
      'a spool that cannot be listed': (
        const RemoteCommandResult(exitCode: kCrontabSpoolDenied),
        UserCrontabsFailure.spoolDenied,
      ),
      'a listing that is no spool': (
        _out('not a path\nalice\n'),
        UserCrontabsFailure.unreadable,
      ),
      'another exit': (
        const RemoteCommandResult(exitCode: 2),
        UserCrontabsFailure.unreadable,
      ),
    };
    for (final MapEntry(key: name, value: (answer, failure)) in cases.entries) {
      test(name, () async {
        final read = await _read(_Link({'klabautermann-spool': answer}));
        expect(read.failure, failure);
        expect(read.jobs, isEmpty);
      });
    }

    test('elevation that needs a password it does not have', () async {
      final read = await _read(
        _Link({}),
        probe: const ElevationProbe(sudoVersionLine: 'Sudo version 1.9.16p2'),
      );
      expect(read.failure, UserCrontabsFailure.elevationRefused);
    });

    test('a link that fails', () async {
      final link = _Link({})
        ..failure = const RemoteCommandException('channel closed');
      expect((await _read(link)).failure, UserCrontabsFailure.transport);
    });
  });

  test('the cron stream\'s rows and snapshot cross masked too', () {
    final cron = parseCron(
      '== crontab_meta ==\nrc=0\n'
      '== crontab ==\n*/5 * * * * env API_TOKEN=abc123 /opt/push\n'
      '== etc_crontab ==\n'
      '17 * * * * root run-parts /etc/cron.hourly\n'
      '== cron_d ==\n\n'
      '== cron_dirs ==\nhourly logrotate\n',
      ParseContext.standard,
    ).value;

    final result = cronResult(cron, null, _now);
    expect(result.cron.jobs.first.command, isNot(contains('abc123')));
    expect(result.cron.jobs.first.raw, isNot(contains('abc123')));
    final row = result.jobs.whereType<CronJobEntry>().first;
    expect(row.job.command, isNot(contains('abc123')));
    expect(
      result.jobs.whereType<PeriodicJobEntry>().single.driverIds,
      hasLength(1),
      reason: 'run-parts is read before masking',
    );
  });
}

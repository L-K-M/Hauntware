// The v1 job history reads (03 §7.7; M5 plan M24): anacron's jobs with
// their commands masked, a timer's last run, cron's logged runs, and why
// a read found nothing.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/jobs/job_history_query.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show kAnacronMissing, kAnacronStampsMarker;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

final class _Link extends TestLinkBase {
  _Link(this.answer);

  final RemoteCommandResult answer;
  Object? failure;
  final commands = <String>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?) throw error;
    return answer;
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

Future<JobHistoryPayload> _query(_Link link, JobHistorySpec query) async {
  final result = await runJobHistoryQuery(_server, 'h-1', query, link: link);
  expect((result.serverId, result.requestId), (_server, 'h-1'));
  return result.payload;
}

void main() {
  test("anacron's jobs come with their stamps and masked commands", () async {
    final link = _Link(
      _out(
        '1\t5\tcron.daily\trun-parts /etc/cron.daily\n'
        '7\t10\tbackup\tbackup.sh --password=hunter2\n'
        '$kAnacronStampsMarker\n'
        'cron.daily 20261020\n',
      ),
    );

    final payload = await _query(link, const AnacronQuery()) as AnacronPayload;

    expect(link.commands.single, contains('klabautermann-anacron'));
    expect(
      [for (final job in payload.jobs) job.identifier],
      ['cron.daily', 'backup'],
    );
    expect(payload.jobs.first.lastRun, DateTime.utc(2026, 10, 20));
    expect(payload.jobs.last.command, 'backup.sh --password=********');
  });

  test('a host without an anacrontab says anacron is not installed', () async {
    final payload = await _query(
      _Link(const RemoteCommandResult(exitCode: kAnacronMissing)),
      const AnacronQuery(),
    );
    expect(
      (payload as JobHistoryFailed).failure,
      JobHistoryFailure.notInstalled,
    );
  });

  test(
    "a timer's last run reads its trigger and the service's result",
    () async {
      final link = _Link(
        _out(
          'Id=backup.timer\n'
          'LastTriggerUSec=Tue 2026-10-20 03:00:00 UTC\n'
          '\n'
          'Id=backup.service\n'
          'Result=exit-code\n'
          'ExecMainStatus=2\n'
          'ExecMainExitTimestamp=Tue 2026-10-20 03:00:05 UTC\n',
        ),
      );

      final payload =
          await _query(
                link,
                const TimerLastRunQuery(
                  timer: 'backup.timer',
                  service: 'backup.service',
                ),
              )
              as TimerLastRunPayload;

      expect(payload.lastRun.lastTrigger, DateTime.utc(2026, 10, 20, 3));
      expect(payload.lastRun.result, 'exit-code');
      expect(payload.lastRun.exitStatus, 2);
    },
  );

  test("cron's logged runs come masked", () async {
    final link = _Link(
      _out(
        '{"__REALTIME_TIMESTAMP":"1792468800000000",'
        '"SYSLOG_IDENTIFIER":"CRON",'
        '"MESSAGE":"(root) CMD (backup.sh --token=abc)"}\n',
      ),
    );

    final payload =
        await _query(link, const CronRunsQuery(lines: 10)) as CronRunsPayload;

    expect(link.commands.single, contains("'journalctl'"));
    final run = payload.runs.single;
    expect(run.user, 'root');
    expect(run.command, 'backup.sh --token=********');
  });

  test('a bad unit name, a failed command and a broken link say why', () async {
    final invalid = _Link(_out(''));
    expect(
      ((await _query(
                invalid,
                const TimerLastRunQuery(timer: 'a b', service: 'x.service'),
              ))
              as JobHistoryFailed)
          .failure,
      JobHistoryFailure.invalidTarget,
    );
    expect(invalid.commands, isEmpty);

    final failed =
        await _query(
              _Link(
                const RemoteCommandResult(exitCode: 1, stderr: 'No journal\n'),
              ),
              const CronRunsQuery(),
            )
            as JobHistoryFailed;
    expect(
      (failed.failure, failed.detail),
      (JobHistoryFailure.failed, 'No journal'),
    );

    final broken = _Link(_out(''))
      ..failure = const RemoteCommandException('channel closed');
    expect(
      ((await _query(broken, const AnacronQuery())) as JobHistoryFailed)
          .failure,
      JobHistoryFailure.noLink,
    );
  });
}

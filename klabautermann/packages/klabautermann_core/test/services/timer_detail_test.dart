// JOB-02's timer schedule read (03 §7.7, D57): `systemctl show` for the
// triggers, then one `systemd-analyze calendar` per expression, as the
// login user, in the user's manager for a user timer; typed failures.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/services/timer_detail.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

/// Answers each command with the first of [answers] whose key it
/// contains, and records it.
final class _Link extends TestLinkBase {
  _Link(this.answers);

  final Map<String, RemoteCommandResult> answers;
  final commands = <String>[];
  Object? failure;

  /// Commands containing this throw [failure]; every command when unset.
  String? failOn;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?
        when failOn == null || command.contains(failOn!)) {
      throw error;
    }
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return const RemoteCommandResult(exitCode: 1, stderr: 'unexpected');
  }
}

const _show = RemoteCommandResult(
  exitCode: 0,
  stdout:
      'TimersCalendar={ OnCalendar=*-*-* 06:00:00 ; next_elapse=n/a }\n'
      'TimersMonotonic={ OnBootUSec=15min ; next_elapse=n/a }\n'
      'RandomizedDelayUSec=1h\n',
);

const _calendar = RemoteCommandResult(
  exitCode: 0,
  stdout:
      '  Normalized form: *-*-* 06:00:00\n'
      '    Next elapse: Wed 2026-10-28 06:00:00 UTC\n'
      '       (in UTC): Wed 2026-10-28 06:00:00 UTC\n'
      '       From now: 18h left\n'
      '       Iter. #2: Thu 2026-10-29 06:00:00 UTC\n'
      '       (in UTC): Thu 2026-10-29 06:00:00 UTC\n'
      '       From now: 1 day 18h left\n',
);

void main() {
  test('reads the triggers, then each expression\'s runs', () async {
    final link = _Link({'systemctl': _show, 'systemd-analyze': _calendar});
    final report = await readTimerDetail(
      _server,
      'backup.timer',
      requestId: 'r-1',
      link: link,
      user: false,
    );
    expect(report.failure, isNull);
    expect(report.detail!.calendar, ['*-*-* 06:00:00']);
    expect(report.detail!.monotonic, hasLength(1));
    expect(report.detail!.randomizedDelay, const Duration(hours: 1));
    expect(report.calendars['*-*-* 06:00:00']!.elapses, hasLength(2));
    expect(link.commands.first, contains("'systemctl' 'show'"));
    expect(link.commands.first, isNot(contains('--user')));
    expect(link.commands.last, contains('--iterations=$kTimerRunsListed'));
  });

  test('a user timer reads the user manager', () async {
    final link = _Link({'systemctl': _show, 'systemd-analyze': _calendar});
    await readTimerDetail(
      _server,
      'sync.timer',
      requestId: 'r-1',
      link: link,
      user: true,
    );
    expect(link.commands.first, contains("'systemctl' '--user' 'show'"));
  });

  test('a calendar read that fails keeps the triggers', () async {
    final link = _Link({'systemctl': _show})
      ..failure = const RemoteCommandException('closed')
      ..failOn = 'systemd-analyze';
    final report = await readTimerDetail(
      _server,
      'backup.timer',
      requestId: 'r-1',
      link: link,
      user: false,
    );
    expect(report.failure, isNull);
    expect(report.detail!.calendar, ['*-*-* 06:00:00']);
    expect(report.calendars, isEmpty);
  });

  test('a calendar read that exits non-zero lists no runs', () async {
    final link = _Link({
      'systemctl': _show,
      'systemd-analyze': const RemoteCommandResult(
        exitCode: 1,
        stderr: 'Failed to parse calendar specification',
      ),
    });
    final report = await readTimerDetail(
      _server,
      'backup.timer',
      requestId: 'r-1',
      link: link,
      user: false,
    );
    expect(report.failure, isNull);
    expect(report.calendars, isEmpty);
  });

  test('failures are typed', () async {
    Future<TimerDetailFailure?> failure(
      _Link link, [
      String unit = 'a.timer',
    ]) async => (await readTimerDetail(
      _server,
      unit,
      requestId: 'r',
      link: link,
      user: false,
    )).failure;

    expect(
      await failure(_Link({}), 'not a timer'),
      TimerDetailFailure.invalidUnit,
    );
    expect(
      await failure(
        _Link({'systemctl': const RemoteCommandResult(exitCode: 127)}),
      ),
      TimerDetailFailure.missing,
    );
    expect(
      await failure(
        _Link({
          'systemctl': const RemoteCommandResult(
            exitCode: 1,
            stderr: 'Failed to connect to bus',
          ),
        }),
      ),
      TimerDetailFailure.unreadable,
    );
    expect(
      await failure(
        _Link({})..failure = const RemoteCommandException('closed'),
      ),
      TimerDetailFailure.transport,
    );
  });
}

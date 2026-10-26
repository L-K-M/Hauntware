// ACC-01 and ACC-02's read (03 §7.9): one command as the login user,
// whose output parses into accounts and logins, and a typed failure when
// the link fails or the output is not the read's.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/services/accounts.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show kAccountsGroupMarker, kAccountsWhoMarker;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

/// Answers every command with [answer], or throws [failure], and records
/// each.
final class _Link extends TestLinkBase {
  _Link(this.answer);

  final RemoteCommandResult answer;
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
    return answer;
  }
}

void main() {
  test('the read runs once, unelevated, and answers what it parsed', () async {
    final link = _Link(
      const RemoteCommandResult(
        exitCode: 0,
        stdout:
            'deploy:x:1000:1000::/home/deploy:/bin/bash\n'
            '$kAccountsGroupMarker\n'
            'docker:x:998:deploy\n'
            '$kAccountsWhoMarker\n'
            'deploy   pts/0        2026-10-26 01:23 (203.0.113.7)\n',
      ),
    );
    final report = await readAccounts(_server, requestId: 'r-1', link: link);
    expect(report.failure, isNull);
    expect(report.requestId, 'r-1');
    final account = report.snapshot!.accounts.single;
    expect(account.rootEquivalence, {RootEquivalence.dockerGroup});
    expect(report.snapshot!.sessions.single.from, '203.0.113.7');
    expect(link.commands.single, contains('getent passwd'));
    expect(link.commands.single, isNot(contains('sudo')));
  });

  test('a failed link and output that is not the read are typed', () async {
    final dropped = _Link(const RemoteCommandResult(exitCode: 0))
      ..failure = const RemoteCommandException('channel closed');
    expect(
      (await readAccounts(_server, requestId: 'r-1', link: dropped)).failure,
      AccountsReportFailure.transport,
    );

    final garbled = _Link(
      const RemoteCommandResult(exitCode: 0, stdout: 'sh: not found\n'),
    );
    expect(
      (await readAccounts(_server, requestId: 'r-2', link: garbled)).failure,
      AccountsReportFailure.unreadable,
    );
  });
}

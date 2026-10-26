// PKG-04's services needing restart (03 §7.8): one elevated check, the
// services and kernel state it names, and each failure typed.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/admin/restarts.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

final class _Link extends TestLinkBase {
  _Link(this.answer);

  RemoteCommandResult answer;
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

Future<RestartReport> _read(_Link link) => readRestarts(
  _server,
  requestId: 'r-1',
  session: AdminSession.test(
    ElevatedExecutor(link, const ElevationProbe(isRoot: true)),
    null,
  ),
);

void main() {
  test('one check names the services and the kernel waiting', () async {
    final link = _Link(
      const RemoteCommandResult(
        exitCode: 0,
        stdout:
            '== tool needrestart\nNEEDRESTART-KSTA: 2\n'
            'NEEDRESTART-SVC: ssh.service\n',
      ),
    );
    final report = await _read(link);

    expect(link.commands.single, contains('needrestart -b'));
    expect((report.serverId, report.requestId), (_server, 'r-1'));
    expect(report.failure, isNull);
    expect(report.check!.services, ['ssh.service']);
    expect(report.check!.kernel, KernelState.abiCompatibleUpgrade);
  });

  test('no tool, and a failed link, are failures', () async {
    final none = await _read(
      _Link(const RemoteCommandResult(exitCode: 0, stdout: '== tool none\n')),
    );
    expect(none.failure, RestartReportFailure.missing);

    final lost = await _read(
      _Link(const RemoteCommandResult(exitCode: 0))
        ..failure = const RemoteCommandException('closed'),
    );
    expect(lost.failure, RestartReportFailure.transport);
  });
}

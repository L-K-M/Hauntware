// NET-06's firewall view (03 §7.4): one elevated read, what it found, and
// each failure typed.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/admin/firewall.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show kFirewallUfwMarker;
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

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

Future<FirewallReport> _read(
  _Link link, {
  ElevationProbe probe = const ElevationProbe(isRoot: true),
}) => readFirewall(
  _server,
  requestId: 'r-1',
  session: AdminSession.test(ElevatedExecutor(link, probe), null),
);

void main() {
  test('one elevated read gives what each tool holds', () async {
    final link = _Link(_out('$kFirewallUfwMarker\nStatus: active\n'));
    final report = await _read(link);
    expect(report.failure, isNull);
    expect(report.read!.ufw!.active, isTrue);
    expect(link.commands.single, contains('ufw status verbose'));
  });

  test('no tool reads as a read that found none', () async {
    final report = await _read(_Link(_out('')));
    expect(report.read!.noTool, isTrue);
  });

  test('a run that failed before printing a section is unreadable, not '
      'a host without a firewall', () async {
    final report = await _read(
      _Link(const RemoteCommandResult(exitCode: 126, stderr: 'denied')),
    );
    expect(report.failure, FirewallReportFailure.unreadable);
    expect(report.read, isNull);
  });

  test('other output is unreadable', () async {
    final report = await _read(_Link(_out('sudo: a password is required\n')));
    expect(report.failure, FirewallReportFailure.unreadable);
  });

  test('elevation that needs a password it does not have', () async {
    final report = await _read(
      _Link(_out('')),
      probe: const ElevationProbe(sudoVersionLine: 'Sudo version 1.9.16p2'),
    );
    expect(report.failure, FirewallReportFailure.elevationRefused);
  });

  test('a link that fails', () async {
    final link = _Link(_out(''))
      ..failure = const RemoteCommandException('channel closed');
    expect((await _read(link)).failure, FirewallReportFailure.transport);
  });
}

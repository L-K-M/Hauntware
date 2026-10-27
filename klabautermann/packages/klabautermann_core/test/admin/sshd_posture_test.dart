// SEC-01's sshd posture (03 §7.10): one elevated `sshd -T` naming the
// probe's user and connection, its settings, and each failure typed.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/admin/sshd_posture.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show kSshdMarker;
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

Future<SshdPostureReport> _read(
  _Link link, {
  HostProfile? profile,
  ElevationProbe probe = const ElevationProbe(isRoot: true),
}) => readSshdPosture(
  _server,
  requestId: 'r-1',
  session: AdminSession.test(ElevatedExecutor(link, probe), null),
  profile: profile,
);

void main() {
  test('one read names the connection and gives its settings', () async {
    final link = _Link(
      _out(
        '$kSshdMarker full\n'
        'port 22\n'
        'permitrootlogin no\n'
        'allowstreamlocalforwarding no\n',
      ),
    );
    final report = await _read(
      link,
      profile: HostProfile(
        user: 'deploy',
        sshConnection: '192.0.2.1 50000 192.0.2.2 22',
      ),
    );
    expect(report.failure, isNull);
    expect(report.posture!.match, SshdMatchContext.connection);
    expect(report.posture!.permitRootLogin, SshdRootLogin.no);
    expect(report.posture!.dockerBlocks, {
      SshdForwardingBlock.allowStreamLocalForwarding,
    });
    expect(
      link.commands.single,
      contains('user=deploy,host=192.0.2.1,addr=192.0.2.1'),
    );
  });

  final cases = {
    'no sshd': (_out('$kSshdMarker missing\n'), SshdPostureFailure.missing),
    'a broken configuration': (
      _out('$kSshdMarker failed\nline 3: Bad configuration option\n'),
      SshdPostureFailure.refused,
    ),
    'other output': (
      _out('sh: 1: sshd: Permission denied\n'),
      SshdPostureFailure.unreadable,
    ),
  };
  for (final MapEntry(key: name, value: (answer, failure)) in cases.entries) {
    test(name, () async {
      final report = await _read(_Link(answer));
      expect(report.failure, failure);
      expect(report.posture, isNull);
    });
  }

  test('a refusal carries sshd\'s error', () async {
    final report = await _read(
      _Link(_out('$kSshdMarker failed\nline 3: Bad configuration option\n')),
    );
    expect(report.detail, 'line 3: Bad configuration option');
  });

  test('elevation that needs a password it does not have', () async {
    final report = await _read(
      _Link(_out('')),
      probe: const ElevationProbe(sudoVersionLine: 'Sudo version 1.9.16p2'),
    );
    expect(report.failure, SshdPostureFailure.elevationRefused);
  });

  test('a link that fails', () async {
    final link = _Link(_out(''))
      ..failure = const RemoteCommandException('channel closed');
    expect((await _read(link)).failure, SshdPostureFailure.transport);
  });
}

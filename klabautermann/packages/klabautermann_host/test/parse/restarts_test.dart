// PKG-04's restart check parser (03 §7.8): needrestart's batch lines,
// needs-restarting's and zypper's unit lists, and no tool at all.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  test('needrestart: the services once each, and the kernel state', () {
    final check = parseRestartCheck('''
== tool needrestart
NEEDRESTART-VER: 3.6
NEEDRESTART-KCUR: 6.1.0-25-amd64
NEEDRESTART-KEXP: 6.1.0-26-amd64
NEEDRESTART-KSTA: 3
NEEDRESTART-SVC: ssh.service
NEEDRESTART-SVC: cron.service
NEEDRESTART-SVC: ssh.service
''');
    expect(check.tool, RestartTool.needrestart);
    expect(check.services, ['ssh.service', 'cron.service']);
    expect(check.kernel, KernelState.versionUpgrade);
  });

  test('needs-restarting and zypper: one unit per line, zypper\'s bare '
      'names as services', () {
    final dnf = parseRestartCheck(
      '== tool needs-restarting\nsshd.service\nchronyd.service\n\n',
    );
    expect(dnf.services, ['sshd.service', 'chronyd.service']);
    expect(dnf.kernel, isNull);

    final zypper = parseRestartCheck('== tool zypper\nsshd\nnscd\n');
    expect(zypper.services, ['sshd.service', 'nscd.service']);
  });

  test('without a tool, and text that is no unit, nothing is listed', () {
    expect(parseRestartCheck('== tool none\n').tool, isNull);
    expect(parseRestartCheck('').tool, isNull);
    final odd = parseRestartCheck(
      '== tool needs-restarting\nUpdating Subscription Management '
      'repositories.\nsshd.service\n',
    );
    expect(odd.services, ['sshd.service']);
  });
}

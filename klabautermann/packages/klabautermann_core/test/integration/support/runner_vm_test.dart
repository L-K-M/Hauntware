// The runner-VM helpers without the runner: when the runner-VM suite
// runs, and the client config its engines import.
import 'dart:io';

import 'package:test/test.dart';

import 'runner_vm.dart';

/// The variables runner_vm.sh exports, but its runtime directory, for a
/// leg that is not running: nothing here dials it.
const _offline = {
  'KLABAUTERMANN_RUNNER_VM_HOST': '127.0.0.1',
  'KLABAUTERMANN_RUNNER_VM_PORT': '1',
  'KLABAUTERMANN_RUNNER_VM_USER': 'klab-vm',
  'KLABAUTERMANN_RUNNER_VM_JOURNAL_USER': 'klab-vm-journal',
  'KLABAUTERMANN_RUNNER_VM_SUDO_USER': 'klab-vm-sudo',
  'KLABAUTERMANN_RUNNER_VM_NOCACHE_USER': 'klab-vm-nocache',
  'KLABAUTERMANN_RUNNER_VM_IDENTITY_FILE': '/nonexistent/identity',
  'KLABAUTERMANN_RUNNER_VM_KNOWN_HOSTS': '/nonexistent/known_hosts',
  'KLABAUTERMANN_RUNNER_VM_HOST_KEY_FINGERPRINT': 'SHA256:host',
  'KLABAUTERMANN_RUNNER_VM_SSHD_PID': '1',
  'KLABAUTERMANN_RUNNER_VM_TIMER': 'klabautermann-runner-vm.timer',
  'KLABAUTERMANN_RUNNER_VM_CALENDAR': 'Mon..Fri *-*-* 04:05:06',
};

void main() {
  test('without runner_vm.sh there is no leg, and the suite skips', () {
    expect(RunnerVm.fromEnvironment({'PATH': '/usr/bin'}), isNull);
  });

  test('a runner_vm.sh that exported only some variables fails the '
      'suite', () {
    final partial = {..._offline}..remove('KLABAUTERMANN_RUNNER_VM_USER');
    final vm = RunnerVm.fromEnvironment(partial);
    expect(vm, isNotNull);
    expect(() => vm!.limitedUser, throwsStateError);
  });

  test('an engine imports the four accounts into runner_vm.sh\'s runtime '
      'directory', () async {
    final runtime = await Directory.systemTemp.createTemp('klab-vm-runtime-');
    addTearDown(() => runtime.delete(recursive: true));
    final vm = RunnerVm.fromEnvironment({
      ..._offline,
      'KLABAUTERMANN_RUNNER_VM_RUNTIME': runtime.path,
    })!;

    // FixtureEngine.launch waits for exactly four hosts imported.
    final engine = await vm.engine('offline import');

    expect(engine.supportDirectory, startsWith('${runtime.path}/'));
    expect(vm.hostKeys, {
      (host: '127.0.0.1', port: 1): {'SHA256:host'},
    });
  });
}

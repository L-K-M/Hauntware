// Spike S4 on the GitHub-hosted Ubuntu runner, a systemd host (03 §7.17;
// 06's spike table; M4 plan E02): which of 7.17's detached runners start
// an operation there, whether it survives the end of the SSH session
// that launched it, and what it leaves behind. Over real SSH as
// runner_vm.sh's throwaway accounts, through seance_core's elevation
// prelude where a row needs root, with E08's wrapper and launch argv:
//
// - `systemd-run` system through the prelude: root-run file ownership,
//   the prelude's deletion of the files, and `--collect` unloading the
//   unit on success and on failure;
// - that a step's `--host` reaches the engine through sudo's env_reset
//   and the unit's clean environment, while root's default context
//   points at a dead socket;
// - `systemd-run --uid` through the prelude, and `--user` with and
//   without linger, each across a logout: the cases read the process
//   and the record as root on the runner, outside any session of the
//   account, so the read keeps no user manager alive;
// - whether `KillUserProcesses` is readable unprivileged;
// - what `sudo -n -l` shows under a NOPASSWD rule scoped to the docker
//   CLI, and that the rule starts no `systemd-run`.
//
// Every case writes what it saw to
// $KLABAUTERMANN_EVIDENCE_DIR/runner-vm/s4/ before its expectations, so
// a failing case still leaves its evidence
// (klabautermann/docs/evidence/s4/). runner_vm.sh starts the leg and
// runs these one at a time; without it they skip.
@Tags(['runner-vm-s4'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        DetachedRunner,
        HostCommands,
        OpRecordField,
        OperationCommands,
        generateOpId,
        kRootOpsDir,
        opUnitName;
import 'package:seance_core/seance_core.dart'
    show ElevatedExecutor, ElevationProbe, SshLink;
import 'package:test/test.dart';

import 'support/runner_vm.dart';
import 'support/s4.dart';

/// Covers one command over the link, a prelude run included.
const _commandTimeout = Duration(seconds: 30);

/// Long enough to outlast the logout and the user manager's stop
/// (`UserStopDelaySec=`, 10 s by default) before the operation ends.
const _survivorSeconds = 30;

/// The line an operation logs when it ends.
const _done = 's4-done';

/// How long a logout may take to end the account's last logind session.
const _logoutWait = Duration(seconds: 30);

/// logind's default `UserStopDelaySec=` and a margin: after it, a user
/// manager that no linger keeps is gone.
const _userStopDelay = Duration(seconds: 15);

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('spike S4 on the runner VM', () {}, skip: runnerVmSkipReason);
    return;
  }
  final evidence = S4Evidence(vm.s4EvidenceDirectory);

  /// Runs [line] through the runner's own passwordless sudo, outside every
  /// session of the leg's accounts: the reads after a logout.
  Future<({int? exitCode, String stdout, String stderr})> asRoot(
    String line,
  ) async {
    final result = await Process.run('sudo', ['-n', 'sh', '-c', line]);
    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  HostRun over(SshLink link) => (line) async {
    final result = await link.run(
      line,
      stdin: const [],
      timeout: _commandTimeout,
    );
    return (
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  };

  /// What the engine's probe would learn of password sudo (03 §6.1):
  /// a version line, no blanket NOPASSWD, and dash's builtin printf.
  Future<ElevationProbe> probe(HostRun run) async => ElevationProbe(
    sudoVersionLine: (await run('sudo -V | head -n 1')).stdout.trim(),
    printfIsBuiltin: (await run(
      'command -V printf',
    )).stdout.contains('builtin'),
  );

  Future<int> uidOf(HostRun run) async =>
      int.parse((await run('id -u')).stdout.trim());

  /// Systemd's load state of [unit]: `not-found` once `--collect` has
  /// unloaded it.
  Future<String> loadState(String unit) async => (await asRoot(
    'systemctl show --property=LoadState --value ${quoteShellWord(unit)}',
  )).stdout.trim();

  /// The owner, group and mode of each of [paths], one line each.
  Future<String> modes(List<String> paths) async => (await asRoot(
    'stat -c "%U:%G %a %n" ${paths.map(quoteShellWord).join(' ')} '
    '2>&1 || true',
  )).stdout;

  /// Waits until [user] has no logind session left, so the logout has
  /// happened; returns whether it did within [_logoutWait].
  Future<bool> loggedOut(String user) => eventually(() async {
    final sessions = await asRoot('loginctl list-sessions --no-legend');
    return !sessions.stdout
        .split('\n')
        .any((line) => line.split(RegExp(r'\s+')).contains(user));
  }, timeout: _logoutWait);

  /// A root-run operation (E08's `rootSystemd` row) of [argv], launched
  /// by klab-vm-sudo through the prelude; returns the launch, the done
  /// record, the log, the files' modes and what `--collect` left.
  Future<Map<String, Object?>> rootOperation(List<String> argv) async {
    final link = await vm.link(vm.sudoUser);
    // Closed however the run ends: an open link keeps the account's logind
    // session, which a later logout test waits to see end.
    try {
      final run = over(link);
      final executor = ElevatedExecutor(link, await probe(run));
      final password = await vm.sudoPassword();
      final id = generateOpId(Random.secure());
      final unit = opUnitName(id);

      final launch = await executor.run(
        OperationCommands.detachedLaunch(
          DetachedRunner.rootSystemd,
          dir: kRootOpsDir,
          id: id,
          uid: await uidOf(run),
          argv: argv,
        ),
        password: password,
        timeout: _commandTimeout,
      );
      final done = launch.exitCode == 0
          ? await untilDone(asRoot, kRootOpsDir, id)
          : null;
      final files = [
        kRootOpsDir,
        '$kRootOpsDir/$id.json',
        '$kRootOpsDir/$id.log',
      ];
      final owned = await modes(files);
      final log = await run('cat -- ${quoteShellWord(files[2])} || true');
      final collected = await eventually(
        () async => await loadState(unit) == 'not-found',
        timeout: const Duration(seconds: 10),
      );

      // The login user owns the files but not the directory, so only the
      // prelude can unlink them (03 §7.17 "Cleanup").
      final cleanup = OperationCommands.opCleanup(kRootOpsDir, [id]);
      final plain = await run(
        HostCommands.commandLine(cleanup, quote: quoteShellWord),
      );
      final elevated = await executor.run(
        cleanup,
        password: password,
        timeout: _commandTimeout,
      );
      final left = await asRoot(
        'ls -A -- ${quoteShellWord(kRootOpsDir)} | '
        'grep -F -e ${quoteShellWord(id)} || true',
      );

      return {
        'user': vm.sudoUser,
        'unit': unit,
        'launch': resultJson((
          exitCode: launch.exitCode,
          stdout: launch.stdout,
          stderr: launch.stderr,
        )),
        'doneRecord': done,
        'modes': owned,
        'log': log.stdout,
        'unitCollected': collected,
        'loadStateAfter': await loadState(unit),
        'cleanupUnelevated': resultJson(plain),
        'cleanupElevated': resultJson((
          exitCode: elevated.exitCode,
          stdout: elevated.stdout,
          stderr: elevated.stderr,
        )),
        'filesLeft': left.stdout,
      };
    } finally {
      await link.close();
    }
  }

  /// A login-user operation of [runner] for [user], launched over a link
  /// that then closes: reads, as root, whether it outlived the logout
  /// and the user manager's stop, and what it recorded.
  Future<Map<String, Object?>> acrossLogout(
    String user,
    DetachedRunner runner,
  ) async {
    final link = await vm.link(user);
    final run = over(link);
    final dir = (await run(userOpsDirLine)).stdout.trim();
    final uid = await uidOf(run);
    final id = generateOpId(Random.secure());
    final argv = OperationCommands.detachedLaunch(
      runner,
      dir: dir,
      id: id,
      uid: uid,
      argv: ['sh', '-c', 'sleep $_survivorSeconds; id -u; echo $_done'],
    );
    final environment = await run(
      r'printf "%s\n" "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-}" '
      r'"DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS-}"',
    );
    final linger = await asRoot(
      'loginctl show-user --property=Linger --value $uid 2>&1 || true',
    );

    final launch = runner.elevated
        ? await ElevatedExecutor(link, await probe(run)).run(
            argv,
            password: await vm.sudoPassword(),
            timeout: _commandTimeout,
          )
        : await link.run(
            HostCommands.commandLine(argv, quote: quoteShellWord),
            stdin: const [],
            timeout: _commandTimeout,
          );
    final record = '$dir/$id.json';
    Map<String, Object?>? running;
    if (launch.exitCode == 0) {
      await eventually(() async {
        running = parseOpRecord(
          (await asRoot('cat -- ${quoteShellWord(record)} 2>/dev/null')).stdout,
        );
        return running != null;
      }, timeout: const Duration(seconds: 10));
    }
    final pid = running?[OpRecordField.pid] as int?;
    final before = pid == null ? null : await procFacts(asRoot, pid);

    await link.close();
    final out = await loggedOut(user);
    await Future<void>.delayed(_userStopDelay);
    final after = pid == null ? null : await procFacts(asRoot, pid);
    final userManager = await asRoot(
      'systemctl is-active user@$uid.service 2>&1 || true',
    );
    final done = after == null
        ? parseOpRecord(
            (await asRoot(
              'cat -- ${quoteShellWord(record)} 2>/dev/null',
            )).stdout,
          )
        : await untilDone(asRoot, dir, id);
    final log = await asRoot(
      'cat -- ${quoteShellWord('$dir/$id.log')} 2>/dev/null || true',
    );
    await asRoot(
      HostCommands.commandLine(
        OperationCommands.opCleanup(dir, [id]),
        quote: quoteShellWord,
      ),
    );

    return {
      'user': user,
      'uid': uid,
      'runner': runner.name,
      'linger': linger.stdout.trim(),
      'sessionEnvironment': environment.stdout,
      'launch': resultJson((
        exitCode: launch.exitCode,
        stdout: launch.stdout,
        stderr: launch.stderr,
      )),
      'runningRecord': running,
      'beforeLogout': procJson(before),
      'loggedOut': out,
      'afterLogout': procJson(after),
      'userManagerAfter': userManager.stdout.trim(),
      'survived': after != null,
      'doneRecord': done,
      'log': log.stdout,
    };
  }

  test('systemd-run system through the prelude runs as root, leaves the '
      "login user's files and unloads with --collect", () async {
    final data = await rootOperation(['sh', '-c', 'id -u; echo $_done']);
    await evidence.write('vm-systemd-run-system', data);

    expect((data['launch']! as Map)['exit'], 0, reason: '$data');
    expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
    expect(data['log'], '0\n$_done\n', reason: 'the command runs as root');
    expect(
      data['modes'],
      allOf(
        contains('root:root 755 $kRootOpsDir\n'),
        contains('${vm.sudoUser}:root 600 $kRootOpsDir/'),
      ),
      reason: 'the wrapper hands the files to the login user',
    );
    expect(data['unitCollected'], isTrue, reason: '$data');
    expect((data['cleanupUnelevated']! as Map)['exit'], isNot(0));
    expect((data['cleanupElevated']! as Map)['exit'], 0, reason: '$data');
    expect(data['filesLeft'], isEmpty);
  });

  test('--collect unloads a failed operation unit too', () async {
    final data = await rootOperation(['sh', '-c', 'exit 3']);
    await evidence.write('vm-collect-failure', data);

    expect((data['launch']! as Map)['exit'], 0, reason: '$data');
    expect((data['doneRecord']! as Map)[OpRecordField.exit], 3);
    expect(data['unitCollected'], isTrue, reason: '$data');
  });

  test("a step's --host reaches the engine through env_reset and the "
      "unit's clean environment", () async {
    final format = ['--format', '{{.Server.Version}}'];
    final withHost = await rootOperation([
      vm.dockerCli,
      '--host',
      'unix://${vm.dockerSocket}',
      'version',
      ...format,
    ]);
    final withoutHost = await rootOperation([
      vm.dockerCli,
      'version',
      ...format,
    ]);
    final environment = await rootOperation(['env']);
    await evidence.write('vm-docker-host', {
      'deadDefaultContext': vm.deadDockerContext,
      'withHost': withHost,
      'withoutHost': withoutHost,
      'unitEnvironment': environment,
    });

    expect((withHost['doneRecord']! as Map)[OpRecordField.exit], 0);
    expect(withHost['log'], matches(RegExp(r'^\d+\.\d+')));
    expect(
      (withoutHost['doneRecord']! as Map)[OpRecordField.exit],
      isNot(0),
      reason: "root's default context is the dead socket",
    );
    expect(environment['log'], isNot(contains('SUDO_')));
  });

  test('systemd-run --uid through the prelude survives the logout without '
      'linger', () async {
    final data = await acrossLogout(
      vm.sudoUser,
      DetachedRunner.loginSystemdUid,
    );
    await evidence.write('vm-systemd-run-uid', data);

    expect((data['launch']! as Map)['exit'], 0, reason: '$data');
    expect(data['linger'], 'no');
    expect(data['loggedOut'], isTrue, reason: '$data');
    expect(data['survived'], isTrue, reason: '$data');
    expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
    expect(
      data['log'],
      '${data['uid']}\n$_done\n',
      reason: 'it runs as the login user, not root',
    );
  });

  test('systemd-run --user with linger survives the logout', () async {
    final data = await acrossLogout(
      vm.lingerUser,
      DetachedRunner.loginSystemdUser,
    );
    await evidence.write('vm-systemd-run-user-linger', data);

    expect((data['launch']! as Map)['exit'], 0, reason: '$data');
    expect(data['linger'], 'yes');
    expect(data['loggedOut'], isTrue, reason: '$data');
    expect(data['survived'], isTrue, reason: '$data');
    expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
  });

  test(
    'systemd-run --user without linger is recorded across the logout',
    () async {
      final data = await acrossLogout(
        vm.limitedUser,
        DetachedRunner.loginSystemdUser,
      );
      await evidence.write('vm-systemd-run-user-no-linger', data);

      // Recorded, not asserted beyond the logout: whether the operation
      // dies with the user manager is what 7.17's `Linger=yes` condition
      // rests on, and the D-row states what this run saw.
      expect(data['linger'], 'no');
      expect(data['loggedOut'], isTrue, reason: '$data');
    },
  );

  test('KillUserProcesses is read unprivileged', () async {
    final link = await vm.link(vm.limitedUser);
    addTearDown(link.close);
    final run = over(link);
    final busctl = await run(
      'busctl get-property org.freedesktop.login1 /org/freedesktop/login1 '
      'org.freedesktop.login1.Manager KillUserProcesses 2>&1',
    );
    final loginctl = await run(
      'loginctl show-user --property=Linger "\$(id -u)" 2>&1',
    );
    final config = await run(
      'systemd-analyze cat-config systemd/logind.conf 2>&1 | '
      'grep -E "^#?KillUserProcesses=" || true',
    );
    await evidence.write('vm-kill-user-processes', {
      'user': vm.limitedUser,
      'busctl': resultJson(busctl),
      'loginctlLinger': resultJson(loginctl),
      'logindConf': resultJson(config),
    });

    expect(busctl.exitCode, 0, reason: busctl.stdout);
    expect(busctl.stdout, matches(RegExp(r'^b (true|false)\n$')));
  });

  test('sudo -n -l shows a rule scoped to docker, which starts no '
      'systemd-run', () async {
    final link = await vm.link(vm.dockerUser);
    addTearDown(link.close);
    final run = over(link);
    final list = await run('sudo -n -l 2>&1');
    final blanket = await run('sudo -n true 2>&1');
    final systemdRun = await run('sudo -n systemd-run --quiet /bin/true 2>&1');
    final docker = await run(
      HostCommands.commandLine([
        'sudo',
        '-n',
        '--',
        vm.dockerCli,
        '--host',
        'unix://${vm.dockerSocket}',
        'version',
        '--format',
        '{{.Server.Version}}',
      ], quote: quoteShellWord),
    );
    await evidence.write('vm-sudo-docker-scoped', {
      'user': vm.dockerUser,
      'dockerCli': vm.dockerCli,
      'sudoList': resultJson(list),
      'sudoTrue': resultJson(blanket),
      'sudoSystemdRun': resultJson(systemdRun),
      'sudoDocker': resultJson(docker),
      'probe': {'sudoNopasswd': blanket.exitCode == 0},
    });

    expect(list.exitCode, 0, reason: list.stdout);
    expect(list.stdout, contains('NOPASSWD: ${vm.dockerCli}'));
    expect(blanket.exitCode, isNot(0), reason: 'rung 2 fails by design');
    expect(systemdRun.exitCode, isNot(0), reason: systemdRun.stdout);
    expect(docker.exitCode, 0, reason: docker.stderr);
    expect(docker.stdout, matches(RegExp(r'^\d+\.\d+')));
  });
}

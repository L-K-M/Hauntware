// Contract tests of the runner-VM leg (03 §11.3, K28a), checked without
// a runner: runner_vm.sh's text, and a copy of it run with stand-ins for
// sudo, OpenSSH, systemd and Dart, so nothing here creates an account,
// starts an sshd or touches the machine.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _limitedUser = 'klab-vm';
const _journalUser = 'klab-vm-journal';
const _sudoUser = 'klab-vm-sudo';
const _lingerUser = 'klab-vm-linger';
const _dockerUser = 'klab-vm-docker';
const _nocacheUser = 'klab-vm-nocache';
const _users = [
  _limitedUser,
  _journalUser,
  _sudoUser,
  _lingerUser,
  _dockerUser,
  _nocacheUser,
];
const _timer = 'klabautermann-runner-vm.timer';

/// How the leg runs docker as root: on the runner's engine by its socket,
/// as root's default context reaches nothing.
const _docker = 'sudo docker --host unix:///var/run/docker.sock';
const _registryContainer = 'klabautermann-runner-vm-registry';
const _stackUsers = [_sudoUser, _lingerUser];
const _testUnits = [
  'klabautermann-vm-test.service',
  'klabautermann-vm-job.service',
  'klabautermann-vm-job.timer',
];

/// The lines of runner_vm.sh that name the machine's paths, which the
/// copy points into its sandbox.
const _systemdLine = "readonly systemd_marker='/run/systemd/system'";
const _sshdLine = "readonly sshd_binary='/usr/sbin/sshd'";
const _privsepLine = "readonly privsep_dir='/run/sshd'";
const _shLine = "readonly system_sh='/bin/sh'";
const _osReleaseLine = "readonly os_release_file='/etc/os-release'";
const _tmpLine = "readonly shared_tmp='/tmp'";
const _lockLine = "readonly lock_file='/tmp/klabautermann-runner-vm.lock'";
const _sudoersLine =
    "readonly sudoers_file='/etc/sudoers.d/klabautermann-runner-vm'";
const _rootOpsLine = "readonly root_ops_parent='/var/lib/klabautermann'";
const _rootManifestLine = "readonly root_manifest_dir='/etc/klabautermann'";
const _editDirLine = "readonly edit_dir='/etc/klabautermann-vm-edit'";
const _rootDockerLine = "readonly root_docker_dir='/root/.docker'";
const _unitDirLine = "readonly unit_dir='/etc/systemd/system'";

/// Bodies of the stand-ins, which log to `$STUB_LOG` and keep the
/// accounts `useradd` made in `$STUB_STATE/users`. sudo runs what only
/// touches the sandbox (mktemp, install without its owner, rm, cat, kill
/// of the stand-in sshd) and logs everything else without running it;
/// it refuses a changing command on a path outside the sandbox, so a
/// path line the copy failed to point there cannot touch the machine.
/// It keeps what chpasswd would read in `$STUB_STATE/chpasswd`, and each
/// crontab it installs in `$STUB_STATE/crontab.<user>` until removed, and
/// in `$STUB_STATE/crontabs` for good.
/// The suite keeps its PID in `$STUB_SUITE_PID` while it runs, exits
/// with `$STUB_SUITE_EXIT` when set, and otherwise stops as package:test
/// does: a first SIGTERM drains, a second stops it. `userdel` takes
/// `$STUB_USERDEL_SECONDS` when set.
const _stubs = {
  'sudo': r'''
if [[ "${1:-}" == -n ]]; then shift; fi
echo "sudo $*" >>"$STUB_LOG"
case "${1:-}" in
  rm | rmdir | install | chmod | tee)
    for arg in "$@"; do
      case "$arg" in
        "$TMPDIR"/*) ;;
        /*) echo "sudo stand-in refuses $arg" >&2; exit 97 ;;
      esac
    done
    ;;
esac
case "${1:-}" in
  chpasswd) cat >"$STUB_STATE/chpasswd" ;;
  crontab)
    if [[ "${4:-}" == - ]]; then
      tee -a "$STUB_STATE/crontabs" >"$STUB_STATE/crontab.$3"
    else
      rm -- "$STUB_STATE/crontab.$3"
    fi
    ;;
  true | mktemp | cat | rm | rmdir | kill | test | tee | chmod) exec "$@" ;;
  install)
    args=()
    while (($#)); do
      case "$1" in
        -o | -g) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec "${args[@]}"
    ;;
  useradd) touch "$STUB_STATE/users/${*: -1}" ;;
  userdel)
    sleep "${STUB_USERDEL_SECONDS:-0}"
    rm -f -- "$STUB_STATE/users/${*: -1}"
    ;;
  */sshd) exec "$@" ;;
esac
''',
  'sshd': r'''
config='' check=0
while (($#)); do
  case "$1" in
    -t) check=1; shift ;;
    -f) config="$2"; shift 2 ;;
    -E) shift 2 ;;
    *) shift ;;
  esac
done
if ((check)); then exit 0; fi
cp -- "$config" "$STUB_STATE/sshd_config"
pidfile="$(awk '$1 == "PidFile" { print $2 }' "$config")"
# Detaches, as sshd without -D does, and writes its PID once it serves.
(
  trap 'rm -f -- "$STUB_STATE/sshd.pid"; echo "sshd stopped" >>"$STUB_LOG"; exit 0' TERM
  echo "$BASHPID" >"$STUB_STATE/sshd.pid"
  echo "$BASHPID" >"$pidfile"
  echo 'sshd started' >>"$STUB_LOG"
  while :; do sleep 0.1; done
) </dev/null >/dev/null 2>&1 &
''',
  'id': r'''
user="${*: -1}"
case "$user" in
  klab-vm | klab-vm-*) ;;
  *) exec /usr/bin/id "$@" ;;
esac
if [[ ! -e "$STUB_STATE/users/$user" ]]; then
  echo "id: '$user': no such user" >&2
  exit 1
fi
if [[ "$1" == -u ]]; then echo 4242; else echo "uid=4242($user)"; fi
''',
  'getent': r'''
mkdir -p "$STUB_STATE/home/$2"
echo "$2:x:4242:4242::$STUB_STATE/home/$2:/bin/sh"
''',
  'pgrep': 'exit 1\n',
  // Found on PATH, so the copy installs no cron; sudo runs it.
  'crontab': 'exit 99\n',
  // As crontab, so the copy installs no acl or attr.
  'setfacl': 'exit 99\n',
  'setfattr': 'exit 99\n',
  'docker':
      r'echo "docker $*" >>"$STUB_LOG"'
      '\n',
  'ssh':
      r'echo "ssh $*" >>"$STUB_LOG"'
      '\n',
  'ssh-keygen': r'''
if [[ "$1" == -lf ]]; then echo '256 SHA256:stub stub (ED25519)'; exit 0; fi
while (($#)); do
  if [[ "$1" == -f ]]; then
    : >"$2"
    echo 'ssh-ed25519 AAAAstub stub' >"$2.pub"
  fi
  shift
done
''',
  'ssh-keyscan': "echo '127.0.0.1 ssh-ed25519 stub'\n",
  'systemctl':
      r'echo "${STUB_SYSTEMCTL_VERSION-systemd 255 (255.4-1ubuntu8)}"'
      '\n',
  'dart': r'''
echo "$$" >"$STUB_SUITE_PID"
trap 'rm -f -- "$STUB_SUITE_PID"' EXIT
env | grep '^KLABAUTERMANN_RUNNER_VM_' | sort >"$STUB_STATE/suite.env"
signals=0
on_term() {
  signals=$((signals + 1))
  if ((signals == 1)); then echo 'suite draining' >>"$STUB_LOG"; return; fi
  echo 'suite stopped' >>"$STUB_LOG"
  exit 143
}
trap on_term TERM
echo "suite started $*" >>"$STUB_LOG"
if [[ -n "${STUB_SUITE_EXIT:-}" ]]; then exit "$STUB_SUITE_EXIT"; fi
for ((i = 0; i < 300; i++)); do sleep 0.1; done
''',
};

void main() {
  late Directory root;
  late String script;
  late String run;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');
    root = Directory.fromUri(workspace.resolve('../'));
    script = File(
      '${root.path}test/integration/runner_vm.sh',
    ).readAsStringSync();
    run = File('${root.path}test/integration/run.sh').readAsStringSync();
  });

  /// [text]'s lines, with continuation lines joined by one space.
  List<String> lines(String text) =>
      text.replaceAll(RegExp(r'\s*\\\n\s*'), ' ').split('\n');

  group('runner_vm.sh', () {
    test('runs in strict mode and arms teardown before it changes the '
        'runner', () {
      final all = script.split('\n');
      int at(String line) {
        final index = all.indexOf(line);
        expect(index, isNonNegative, reason: 'runner_vm.sh has no "$line"');
        return index;
      }

      expect(all, contains('set -euo pipefail'));
      final trap = at('trap on_exit EXIT');
      for (final change in [
        'create_user "\$limited_user"',
        'create_user "\$journal_user" --groups systemd-journal',
        'sudo -n systemd-run --quiet --unit="\$timer_unit" '
            '--on-calendar="\$calendar" \\',
        '  install_package openssh-server',
        '  install_package cron',
        'install_test_units',
        'install_crontabs',
      ]) {
        expect(at(change), greaterThan(trap), reason: change);
      }
      // Teardown ignores further signals and removes each account.
      expect(script, contains("  trap '' INT TERM HUP\n"));
      expect(script, contains('remove_user "\$user" || cleanup=1'));
      expect(script, contains('sudo -n userdel --remove "\$user"'));
    });

    test('runs its own sshd on loopback, never the system sshd', () {
      final port = RegExp(
        r'^readonly sshd_port=(\d+)$',
        multiLine: true,
      ).firstMatch(script);
      expect(int.parse(port![1]!), isNot(22));
      expect(script, contains("readonly sshd_host='127.0.0.1'"));
      expect(script, contains(r'ListenAddress $sshd_host:$sshd_port'));
      expect(
        lines(script),
        contains(
          'sudo -n "\$sshd_binary" -E "\$sshd_dir/sshd.log" -f '
          '"\$sshd_dir/sshd_config" 8>&- 9>&-',
        ),
      );
      // Not the system config, its service or its port.
      expect(script, isNot(contains('/etc/ssh')));
      expect(script, isNot(matches(RegExp(r'systemctl\s+\S+\s+"?ssh'))));
      expect(script, isNot(matches(RegExp(r'^\s*Port\s', multiLine: true))));
    });

    test('puts only the second account in a journal group (LOG-04), and '
        'adds the S4 and actions accounts', () {
      final creates = [
        for (final line in lines(script))
          if (line.startsWith('create_user ')) line,
      ];
      expect(creates, [
        'create_user "\$limited_user"',
        'create_user "\$journal_user" --groups systemd-journal',
        'create_user "\$sudo_user"',
        'create_user "\$linger_user" --groups docker',
        'create_user "\$docker_user"',
        'create_user "\$nocache_user"',
      ]);
      expect(script, contains("readonly limited_user='$_limitedUser'"));
      expect(script, contains("readonly journal_user='$_journalUser'"));
    });

    test('exports every variable the runner-VM suite reads', () {
      final support = File(
        '${root.path}packages/klabautermann_core/test/integration/support/'
        'runner_vm.dart',
      ).readAsStringSync();
      final variables = {
        for (final match in RegExp(r"_variable\('(\w+)'\)").allMatches(support))
          'KLABAUTERMANN_RUNNER_VM_${match[1]}',
      };
      expect(variables, isNotEmpty);
      final exported = {
        for (final line in lines(script))
          if (RegExp(r'^export (\w+)=').firstMatch(line) case final m?) m[1],
      };
      expect(exported, containsAll(variables));
    });

    test('runs the tagged suite one at a time', () {
      expect(
        lines(script).join('\n'),
        contains(
          'run_child "\$dart_binary" test --concurrency=1 '
          "--tags 'runner-vm || runner-vm-s4 || runner-vm-s6' "
          '"\${reporter[@]}" '
          'packages/klabautermann_core/test/integration',
        ),
      );
      for (final path in [
        'dart_test.yaml',
        'packages/klabautermann_core/dart_test.yaml',
      ]) {
        final tags = loadYaml(File('${root.path}$path').readAsStringSync());
        for (final tag in ['runner-vm', 'runner-vm-s4', 'runner-vm-s6']) {
          expect((tags['tags'] as YamlMap).containsKey(tag), isTrue);
        }
      }
    });
  });

  test('run.sh runs the leg once, after the suites, and stops it on '
      'exit', () {
    final all = run.split('\n');
    final start = all.indexWhere((l) => l.startsWith('# ---- Runner-VM leg'));
    final end = all.indexOf(
      '# ---- End of the runner-VM leg -------------------------------------------',
    );
    expect(start, greaterThan(all.lastIndexOf("suites_pid=''")));
    expect(end, greaterThan(start));
    final calls = [
      for (final (i, line) in all.indexed)
        if (line.contains('runner_vm.sh"')) i,
    ];
    expect(calls, hasLength(1));
    expect(calls.single, allOf(greaterThan(start), lessThan(end)));
    expect(run, contains('    kill "\$runner_vm_pid" 2>/dev/null || true\n'));
    expect(
      File('${root.path}test/integration/runner_vm.sh').statSync().modeString(),
      startsWith('rwx'),
    );
  });

  group('a copy with stand-ins', () {
    late Directory sandbox;
    late Directory bin;
    late Directory state;
    late File copy;
    late File log;
    late File suitePid;

    setUp(() async {
      for (final line in [
        _systemdLine,
        _sshdLine,
        _privsepLine,
        _shLine,
        _osReleaseLine,
        _tmpLine,
        _lockLine,
        _sudoersLine,
        _rootOpsLine,
        _rootManifestLine,
        _editDirLine,
        _rootDockerLine,
        _unitDirLine,
      ]) {
        expect(script, contains(line));
      }
      sandbox = await Directory.systemTemp.createTemp('klabautermann-vm-');
      bin = Directory('${sandbox.path}/bin')..createSync();
      state = Directory('${sandbox.path}/state')..createSync();
      Directory('${state.path}/users').createSync();
      Directory('${sandbox.path}/tmp').createSync();
      Directory('${sandbox.path}/systemd').createSync();
      Directory('${sandbox.path}/sudoers.d').createSync();
      Directory('${sandbox.path}/units').createSync();
      log = File('${sandbox.path}/stub.log');
      suitePid = File('${sandbox.path}/suite.pid');
      addTearDown(() async {
        // Only a copy that left them running leaves the files.
        for (final file in [suitePid, File('${state.path}/sshd.pid')]) {
          if (!file.existsSync()) continue;
          final pid = int.tryParse(file.readAsStringSync().trim());
          if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
        }
        await sandbox.delete(recursive: true);
      });

      for (final MapEntry(key: name, value: body) in _stubs.entries) {
        File(
          '${bin.path}/$name',
        ).writeAsStringSync('#!/usr/bin/env bash\n$body');
      }
      File('${sandbox.path}/dash').writeAsStringSync('');
      Link('${sandbox.path}/sh').createSync('${sandbox.path}/dash');
      File(
        '${sandbox.path}/os-release',
      ).writeAsStringSync('ID=ubuntu\nVERSION_ID="24.04"\n');
      final integration = Directory(
        '${sandbox.path}/klabautermann/test/integration',
      )..createSync(recursive: true);
      copy = File('${integration.path}/runner_vm.sh')
        ..writeAsStringSync(
          script
              .replaceFirst(
                _systemdLine,
                "readonly systemd_marker='${sandbox.path}/systemd'",
              )
              .replaceFirst(
                _sshdLine,
                "readonly sshd_binary='${bin.path}/sshd'",
              )
              .replaceFirst(
                _privsepLine,
                "readonly privsep_dir='${sandbox.path}/privsep'",
              )
              .replaceFirst(_shLine, "readonly system_sh='${sandbox.path}/sh'")
              .replaceFirst(
                _osReleaseLine,
                "readonly os_release_file='${sandbox.path}/os-release'",
              )
              .replaceFirst(
                _tmpLine,
                "readonly shared_tmp='${sandbox.path}/tmp'",
              )
              .replaceFirst(
                _lockLine,
                "readonly lock_file='${sandbox.path}/leg.lock'",
              )
              .replaceFirst(
                _sudoersLine,
                "readonly sudoers_file='${sandbox.path}/sudoers.d/leg'",
              )
              .replaceFirst(
                _rootOpsLine,
                "readonly root_ops_parent='${sandbox.path}/var-lib'",
              )
              .replaceFirst(
                _rootManifestLine,
                "readonly root_manifest_dir='${sandbox.path}/etc-klab'",
              )
              .replaceFirst(
                _editDirLine,
                "readonly edit_dir='${sandbox.path}/edit'",
              )
              .replaceFirst(
                _rootDockerLine,
                "readonly root_docker_dir='${sandbox.path}/root-docker'",
              )
              .replaceFirst(
                _unitDirLine,
                "readonly unit_dir='${sandbox.path}/units'",
              ),
        );
      final chmod = await Process.run('chmod', [
        '+x',
        for (final name in _stubs.keys) '${bin.path}/$name',
      ]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
    });

    /// Starts the copy with [environment] on top of the stand-ins'.
    Future<({Process process, Future<int> exitCode, StringBuffer output})>
    start(Map<String, String> environment) async {
      final process = await Process.start(
        'bash',
        [copy.path],
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'TMPDIR': sandbox.path,
          'STUB_LOG': log.path,
          'STUB_STATE': state.path,
          'STUB_SUITE_PID': suitePid.path,
          ...environment,
        },
        includeParentEnvironment: false,
      );
      final output = StringBuffer();
      final drained = [
        process.stdout.transform(utf8.decoder).listen(output.write).asFuture(),
        process.stderr.transform(utf8.decoder).listen(output.write).asFuture(),
      ];
      // The exit can arrive before the last output does, and a test reads
      // the output once the exit code is in.
      final exitCode = process.exitCode.then(
        (code) => Future.wait(drained).then((_) => code),
      );
      return (process: process, exitCode: exitCode, output: output);
    }

    const onRunner = {
      'GITHUB_ACTIONS': 'true',
      'RUNNER_ENVIRONMENT': 'github-hosted',
    };

    List<String> logged() => log.existsSync() ? log.readAsLinesSync() : [];

    Future<void> untilLogged(String line, StringBuffer output) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!logged().any((l) => l.startsWith(line))) {
        if (DateTime.now().isAfter(deadline)) {
          fail('never logged "$line":\n$output\n${logged().join('\n')}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    /// What every teardown leaves: no account, no sshd, no directory.
    void expectTornDown() {
      final lines = logged();
      expect(
        lines,
        containsAll([
          'sudo systemctl stop $_timer',
          'sudo systemctl stop ${_testUnits.join(' ')}',
          'sudo systemctl daemon-reload',
          'sshd stopped',
          for (final user in _users) 'sudo crontab -u $user -r',
          for (final user in _users) 'sudo userdel --remove $user',
          'sudo rm -f -- ${sandbox.path}/sudoers.d/leg',
          for (final user in _stackUsers)
            '$_docker compose --project-name $user down --remove-orphans '
                '--volumes --timeout 1',
          '$_docker rm --force --volumes $_registryContainer',
        ]),
        reason: lines.join('\n'),
      );
      expect(
        Directory('${sandbox.path}/units').listSync(),
        isEmpty,
        reason: 'a test unit is left',
      );
      expect(
        state.listSync().where((e) => e.path.contains('crontab.')),
        isEmpty,
        reason: 'a crontab is left',
      );
      expect(
        Directory('${state.path}/users').listSync(),
        isEmpty,
        reason: 'an account is left',
      );
      final left = [
        ...sandbox.listSync().where((e) => e.path.contains('runner-vm.')),
        ...Directory('${sandbox.path}/tmp').listSync(),
      ];
      expect(left, isEmpty, reason: 'a directory is left');
      expect(
        Directory('${sandbox.path}/privsep').existsSync(),
        isFalse,
        reason: 'the privilege separation directory is left',
      );
    }

    for (final environment in [
      const <String, String>{},
      const {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'},
    ]) {
      test('skips without a privileged call off a GitHub-hosted runner '
          '($environment)', () async {
        final (process: _, :exitCode, :output) = await start(environment);

        expect(await exitCode, 0, reason: '$output');
        expect('$output', contains('::notice::Runner-VM leg skipped'));
        expect(logged(), isEmpty);
      });
    }

    test('refuses to run over an account it did not create', () async {
      File('${state.path}/users/$_limitedUser').createSync();

      final (process: _, :exitCode, :output) = await start(onRunner);

      expect(await exitCode, 1, reason: '$output');
      expect('$output', contains('$_limitedUser exists'));
      expect(logged(), isNot(contains(matches('useradd|userdel'))));
      expect(File('${state.path}/users/$_limitedUser').existsSync(), isTrue);
    });

    test('fails without a systemd version, before any account', () async {
      final (process: _, :exitCode, :output) = await start({
        ...onRunner,
        'STUB_SYSTEMCTL_VERSION': 'not systemd',
      });

      expect(await exitCode, 1, reason: '$output');
      expect('$output', contains('no systemd version from systemctl'));
      expect(logged(), isNot(contains(startsWith('sudo useradd'))));
      expect(
        sandbox.listSync().where((e) => e.path.contains('runner-vm.')),
        isEmpty,
        reason: 'a directory is left',
      );
    });

    test('sets up the leg, runs the suite and tears down after it', () async {
      final (process: _, :exitCode, :output) = await start({
        ...onRunner,
        'STUB_SUITE_EXIT': '0',
      });

      expect(await exitCode, 0, reason: '$output');
      final lines = logged();
      expect(
        lines,
        containsAllInOrder([
          startsWith('sudo useradd '),
          startsWith('sudo useradd '),
          'sudo install -d -m 0755 -o root -g root ${sandbox.path}/privsep',
          'sshd started',
          for (final unit in _testUnits)
            matches(
              RegExp(
                '^sudo install -m 0644 -o root -g root '
                '${RegExp.escape(sandbox.path)}/klabautermann-runner-vm\\.\\w+/'
                '${RegExp.escape(unit)} '
                '${RegExp.escape('${sandbox.path}/units/$unit')}\$',
              ),
            ),
          'sudo systemctl daemon-reload',
          'sudo systemctl start ${_testUnits.first} ${_testUnits.last}',
          startsWith(
            'sudo systemd-run --quiet --unit=klabautermann-runner-vm ',
          ),
          startsWith('suite started test --concurrency=1 --tags runner-vm'),
          'sudo systemctl stop $_timer',
          'sshd stopped',
        ]),
        reason: lines.join('\n'),
      );
      expect(
        lines.where((l) => l.startsWith('sudo useradd ')).elementAt(1),
        endsWith('--groups systemd-journal $_journalUser'),
      );
      for (final user in _users) {
        expect(
          File('${state.path}/home/$user/.ssh/authorized_keys').existsSync(),
          isTrue,
          reason: 'each account has a home of its own',
        );
      }
      final config = File('${state.path}/sshd_config').readAsLinesSync();
      expect(config, contains('ListenAddress 127.0.0.1:2243'));
      expect(config, contains('AllowUsers ${_users.join(' ')}'));
      expect(config, contains('AuthenticationMethods publickey'));
      final exported = File('${state.path}/suite.env').readAsStringSync();
      expect(exported, contains('KLABAUTERMANN_RUNNER_VM_SSHD_PID='));
      expect(exported, contains('KLABAUTERMANN_RUNNER_VM_TIMER=$_timer\n'));
      expect(
        exported,
        contains('KLABAUTERMANN_RUNNER_VM_CRONTAB_USERS=${_users.join(' ')}\n'),
      );
      // One crontab each, installed before the suite and never run.
      expect(
        lines,
        containsAllInOrder([
          for (final user in _users) 'sudo crontab -u $user -',
          startsWith('suite started '),
        ]),
      );
      // The registry, each stack's image in it, and each stack in its
      // account's home, all before the suite.
      expect(
        lines,
        containsAllInOrder([
          startsWith(
            '$_docker run --detach --quiet --name $_registryContainer '
            '--publish 127.0.0.1:5243:5000 ',
          ),
          for (final user in _stackUsers)
            '$_docker push --quiet 127.0.0.1:5243/klabautermann-runner-vm/'
                '$user:1',
          for (final user in _stackUsers)
            '$_docker compose --project-name $user --project-directory '
                '${state.path}/home/$user/stack --file '
                '${state.path}/home/$user/stack/compose.yaml up --detach '
                '--quiet-pull',
          startsWith('suite started '),
        ]),
        reason: lines.join('\n'),
      );
      for (final user in _stackUsers) {
        expect(
          File(
            '${state.path}/home/$user/stack/compose.yaml',
          ).readAsStringSync(),
          contains('image: 127.0.0.1:5243/klabautermann-runner-vm/$user:1\n'),
        );
      }
      expect(File('${state.path}/crontabs').readAsLinesSync(), [
        for (final user in _users)
          '5 4 1 1 * curl -s https://ops:secret-$user@example.invalid/ping',
      ]);
      expectTornDown();
    });

    test('gives the sudo accounts fresh passwords that no argv, log or '
        'variable carries, and checks the drop-in first', () async {
      final (process: _, :exitCode, :output) = await start({
        ...onRunner,
        'STUB_SUITE_EXIT': '0',
      });

      expect(await exitCode, 0, reason: '$output');
      final fed = File('${state.path}/chpasswd').readAsStringSync();
      final match = RegExp(
        '^$_sudoUser:([0-9a-f]{48})\n$_lingerUser:([0-9a-f]{48})\n'
        '$_nocacheUser:([0-9a-f]{48})\n\$',
      ).firstMatch(fed);
      expect(match, isNotNull, reason: 'chpasswd read "$fed"');
      final passwords = [match![1]!, match[2]!, match[3]!];
      expect(passwords.toSet(), hasLength(3), reason: 'one each');
      final lines = logged();
      final exported = File('${state.path}/suite.env').readAsStringSync();
      for (final (name, text) in [
        ('the log of every command', lines.join('\n')),
        ('the output', '$output'),
        ('the exported variables', exported),
      ]) {
        for (final password in passwords) {
          expect(text, isNot(contains(password)), reason: name);
        }
      }
      expect(exported, contains('KLABAUTERMANN_RUNNER_VM_SUDO_PASSWORD_FILE='));
      expect(
        exported,
        contains('KLABAUTERMANN_RUNNER_VM_LINGER_PASSWORD_FILE='),
      );
      expect(
        exported,
        contains('KLABAUTERMANN_RUNNER_VM_NOCACHE_PASSWORD_FILE='),
      );

      final drop = '${sandbox.path}/sudoers.d/leg';
      expect(
        lines,
        containsAllInOrder([
          'sudo chpasswd',
          matches(RegExp(r'^sudo visudo -cf \S+/sudoers$')),
          startsWith('sudo install -m 0440 -o root -g root '),
          'sudo visudo -cf $drop',
          startsWith('suite started '),
          'sudo rm -f -- $drop',
        ]),
        reason: lines.join('\n'),
      );
      expect(File(drop).existsSync(), isFalse, reason: 'the drop-in is left');
      expect(
        lines,
        containsAllInOrder([
          'sudo loginctl enable-linger $_lingerUser',
          startsWith('suite started '),
          'sudo loginctl disable-linger $_lingerUser',
        ]),
      );
    });

    test('exits with the suite\'s status after teardown', () async {
      final (process: _, :exitCode, :output) = await start({
        ...onRunner,
        'STUB_SUITE_EXIT': '3',
      });

      expect(await exitCode, 3, reason: '$output');
      expectTornDown();
    });

    test('a signal stops the suite, then tears down', () async {
      final (:process, :exitCode, :output) = await start(onRunner);
      await untilLogged('suite started', output);

      process.kill();
      final status = await exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          fail('runner_vm.sh did not exit:\n$output');
        },
      );
      expect(status, isNot(0), reason: '$output');
      final lines = logged();
      expect(
        lines.indexOf('suite stopped'),
        allOf(
          isNonNegative,
          lessThan(lines.indexOf('sudo systemctl stop $_timer')),
        ),
        reason: lines.join('\n'),
      );
      expectTornDown();
    });

    test('a second signal during teardown does not cut it short', () async {
      final (:process, :exitCode, :output) = await start({
        ...onRunner,
        'STUB_USERDEL_SECONDS': '1',
      });
      await untilLogged('suite started', output);

      process.kill();
      await untilLogged('sudo userdel', output);
      process.kill();

      final status = await exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          fail('runner_vm.sh did not exit:\n$output');
        },
      );
      expect(status, isNot(0), reason: '$output');
      expectTornDown();
    });
  });
}

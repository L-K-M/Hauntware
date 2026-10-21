// How run.sh ends (03 §11.3, §11.4, D53), checked without Docker: a copy
// of it runs with stand-ins for Docker, OpenSSH, Dart and the runner-VM
// leg.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The copy takes its own lock, so the test neither waits for nor blocks
/// a real fixture run on this machine.
const _lockLine = "readonly lock_file='/tmp/klabautermann-fixture.lock'";

/// Bodies of the stand-ins, which log to `$STUB_LOG`. `dart test` plays
/// the suites, or with `--tags soak` the soak; either keeps its PID in
/// `$STUB_SUITES_PID` while it runs. The suites exit with
/// `$STUB_SUITES_EXIT` when it is set; the soak exits at once with
/// `$STUB_SOAK_EXIT` (default 0), having written soak.json unless
/// `$STUB_SOAK_NO_EVIDENCE` is set, or with `$STUB_SOAK_HOLD` set it runs.
/// A run stops as package:test does: a first SIGTERM lets the running test
/// finish, here 30 s after the start, and a second one stops it at once.
/// `compose down` takes `$STUB_DOWN_SECONDS` when it is set. `ssh` plays
/// the Docker host, where `docker load` reports an image. With
/// `--tags inventory`, `dart test` plays the inventory session and exits
/// at once with `$STUB_INVENTORY_EXIT` (default 0); `dart run` of
/// inventory.dart plays its check, exiting with
/// `$STUB_INVENTORY_CHECK_EXIT` (default 0). `curl` plays the sync
/// service answering its readiness probe.
const _stubs = {
  'docker': r'''
echo "docker $*" >>"$STUB_LOG"
if [[ "$*" == *' port '* ]]; then echo '127.0.0.1:49152'; fi
if [[ "$*" == *' exec '* ]]; then echo 'ssh-ed25519 AAAAstub root@stub'; fi
if [[ "$*" == *' down '* ]]; then sleep "${STUB_DOWN_SECONDS:-0}"; fi
''',
  'ssh-keygen': r'''
if [[ "$1" == -lf ]]; then echo '256 SHA256:stub stub (ED25519)'; exit 0; fi
while (($#)); do
  if [[ "$1" == -f ]]; then : >"$2"; : >"$2.pub"; fi
  shift
done
''',
  'ssh-keyscan': "echo '127.0.0.1 ssh-ed25519 stub'\n",
  'ssh-agent': r'''
echo "ssh-agent $*" >>"$STUB_LOG"
if [[ "$1" == -s ]]; then echo 'SSH_AGENT_PID=0; export SSH_AGENT_PID;'; fi
''',
  'ssh-add': '',
  'curl': r'''
echo "curl $*" >>"$STUB_LOG"
echo 404
''',
  'ssh': r'''
echo "ssh $*" >>"$STUB_LOG"
cat >/dev/null
if [[ "$*" == *' docker load '* ]]; then echo 'Loaded image ID: sha256:stub'; fi
''',
  'dart': r'''
if [[ "$1" == run && "$*" == *inventory.dart* ]]; then
  echo 'inventory checked' >>"$STUB_LOG"
  exit "${STUB_INVENTORY_CHECK_EXIT:-0}"
fi
if [[ "$1" == run ]]; then cat >/dev/null; exit 0; fi
if [[ " $* " == *' --tags inventory '* ]]; then
  echo 'inventory started' >>"$STUB_LOG"
  exit "${STUB_INVENTORY_EXIT:-0}"
fi
run=suites
exit_status="${STUB_SUITES_EXIT:-}"
if [[ " $* " == *' --tags soak '* ]]; then
  run=soak
  echo "soak seconds $KLABAUTERMANN_SOAK_SECONDS dir $KLABAUTERMANN_SOAK_DIR" >>"$STUB_LOG"
  exit_status=''
  if [[ -z "${STUB_SOAK_HOLD:-}" ]]; then exit_status="${STUB_SOAK_EXIT:-0}"; fi
fi
echo "$$" >"$STUB_SUITES_PID"
trap 'rm -f -- "$STUB_SUITES_PID"' EXIT
signals=0
on_term() {
  signals=$((signals + 1))
  if ((signals == 1)); then echo "$run draining" >>"$STUB_LOG"; return; fi
  echo "$run stopped" >>"$STUB_LOG"
  exit 143
}
trap on_term TERM
echo "$run started" >>"$STUB_LOG"
if [[ "$run" == soak && -z "${STUB_SOAK_NO_EVIDENCE:-}" ]]; then
  echo '{}' >"$KLABAUTERMANN_SOAK_DIR/soak.json"
fi
if [[ -n "$exit_status" ]]; then exit "$exit_status"; fi
for ((i = 0; i < 300; i++)); do sleep 0.1; done
''',
};

/// The runner-VM leg's stand-in, beside the copy of run.sh: it exits at
/// once with `$STUB_RUNNER_VM_EXIT` (default 0), or with
/// `$STUB_RUNNER_VM_HOLD` set runs until a SIGTERM, as runner_vm.sh does
/// until its teardown.
const _runnerVm = r'''
echo 'runner-vm started' >>"$STUB_LOG"
if [[ -z "${STUB_RUNNER_VM_HOLD:-}" ]]; then exit "${STUB_RUNNER_VM_EXIT:-0}"; fi
trap 'echo "runner-vm stopped" >>"$STUB_LOG"; exit 143' TERM
for ((i = 0; i < 300; i++)); do sleep 0.1; done
''';

void main() {
  late Directory sandbox;
  late File suitesPid;
  late File log;
  late File run;
  late Directory bin;

  setUp(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');
    final script = File.fromUri(
      workspace.resolve('../test/integration/run.sh'),
    ).readAsStringSync();
    expect(script, contains(_lockLine));

    sandbox = await Directory.systemTemp.createTemp('klabautermann-run-');
    suitesPid = File('${sandbox.path}/suites.pid');
    log = File('${sandbox.path}/stub.log');
    addTearDown(() async {
      // Only a run.sh that left the suites running leaves the file.
      if (suitesPid.existsSync()) {
        final pid = int.tryParse(suitesPid.readAsStringSync().trim());
        if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
      }
      await sandbox.delete(recursive: true);
    });

    final integration = Directory(
      '${sandbox.path}/klabautermann/test/integration',
    )..createSync(recursive: true);
    run = File('${integration.path}/run.sh')
      ..writeAsStringSync(
        script.replaceFirst(
          _lockLine,
          "readonly lock_file='${sandbox.path}/fixture.lock'",
        ),
      );
    bin = Directory('${sandbox.path}/bin')..createSync();
    for (final MapEntry(key: name, value: body) in _stubs.entries) {
      File('${bin.path}/$name').writeAsStringSync('#!/usr/bin/env bash\n$body');
    }
    final runnerVm = File('${integration.path}/runner_vm.sh')
      ..writeAsStringSync('#!/usr/bin/env bash\n$_runnerVm');
    // What run.sh pipes to the Docker host, which the stand-in ignores.
    File('${integration.path}/seed_docker.sh').writeAsStringSync('exit 0\n');
    File('${integration.path}/inventory.sh').writeAsStringSync('exit 0\n');
    final chmod = await Process.run('chmod', [
      '+x',
      for (final name in _stubs.keys) '${bin.path}/$name',
      runnerVm.path,
    ]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
  });

  /// Starts the copy, and completes once the suites have started.
  Future<({Process process, Future<int> exitCode, StringBuffer output})>
  startRun({
    String? suitesExit,
    String? downSeconds,
    String? runnerVmExit,
    bool holdRunnerVm = false,
    String? inventoryExit,
    String? inventoryCheckExit,
    String? soakExit,
    bool holdSoak = false,
    bool soakEvidence = true,
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      'bash',
      [run.path],
      environment: {
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'TMPDIR': sandbox.path,
        'STUB_LOG': log.path,
        'STUB_SUITES_PID': suitesPid.path,
        'STUB_SUITES_EXIT': ?suitesExit,
        'STUB_DOWN_SECONDS': ?downSeconds,
        'STUB_RUNNER_VM_EXIT': ?runnerVmExit,
        'STUB_INVENTORY_EXIT': ?inventoryExit,
        'STUB_INVENTORY_CHECK_EXIT': ?inventoryCheckExit,
        if (holdRunnerVm) 'STUB_RUNNER_VM_HOLD': '1',
        'STUB_SOAK_EXIT': ?soakExit,
        if (holdSoak) 'STUB_SOAK_HOLD': '1',
        if (!soakEvidence) 'STUB_SOAK_NO_EVIDENCE': '1',
        ...environment,
      },
      includeParentEnvironment: false,
    );
    final output = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(output.write);
    process.stderr.transform(utf8.decoder).listen(output.write);

    var exited = false;
    final exitCode = process.exitCode.whenComplete(() => exited = true);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!log.existsSync() ||
        !log.readAsLinesSync().contains('suites started')) {
      if (exited || DateTime.now().isAfter(deadline)) {
        fail('The suites never started:\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return (process: process, exitCode: exitCode, output: output);
  }

  /// The log from `compose up` to the first `compose down` after it.
  List<String> fixtureLifetime() {
    final lines = log.readAsLinesSync();
    final up = lines.indexWhere((line) => line.contains(' up --detach'));
    final down = lines.indexWhere(
      (line) => line.endsWith(' down --volumes --remove-orphans'),
      up,
    );
    expect(up, isNonNegative, reason: lines.join('\n'));
    expect(down, greaterThan(up), reason: lines.join('\n'));
    return lines.sublist(up, down + 1);
  }

  test('a signal to run.sh stops the suites before it removes the '
      'fixture', () async {
    final (:process, :exitCode, :output) = await startRun();

    process.kill();
    final status = await exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        fail('run.sh waited for the running test to finish:\n$output');
      },
    );
    expect(status, isNot(0), reason: '$output');
    expect(
      fixtureLifetime(),
      contains('suites stopped'),
      reason: 'run.sh did not stop the suites before compose down',
    );
  });

  test('a second signal during teardown does not cut it short', () async {
    final (:process, :exitCode, :output) = await startRun(downSeconds: '2');

    process.kill();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!log.readAsLinesSync().contains('suites stopped')) {
      if (DateTime.now().isAfter(deadline)) {
        fail('run.sh never reached compose down:\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // compose down follows at once and takes 2 s: signal it mid-way.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    process.kill();

    final status = await exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        fail('run.sh did not exit:\n$output');
      },
    );
    expect(status, isNot(0), reason: '$output');
    final lines = log.readAsLinesSync();
    expect(
      lines.skip(lines.indexOf('suites stopped')),
      containsAllInOrder([
        endsWith(' down --volumes --remove-orphans'),
        'ssh-agent -k',
      ]),
      reason: 'run.sh did not finish its teardown',
    );
    expect(
      sandbox.listSync().where(
        (entry) => entry.path.contains('/klabautermann-fixture.'),
      ),
      isEmpty,
      reason: 'run.sh left its key directory behind',
    );
  });

  test('run.sh exits with the suites\' status after teardown', () async {
    final (process: _, :exitCode, :output) = await startRun(suitesExit: '3');

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      3,
      reason: '$output',
    );
    // Its expectations check that teardown ran after the suites, and
    // the runner-VM leg and the soak run whatever they gave.
    expect(
      fixtureLifetime(),
      containsAllInOrder(['runner-vm started', 'soak started']),
    );
  });

  test('run.sh exits with the inventory session\'s status once the suites '
      'pass, and checks no diff after a failed session', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      inventoryExit: '6',
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      6,
      reason: '$output',
    );
    final lifetime = fixtureLifetime();
    expect(
      lifetime,
      containsAllInOrder([
        'suites started',
        contains(' exec -T --user root docker-sshd sh -s -- /'),
        'inventory started',
        contains(' exec -T --user root docker-sshd sh -s -- /'),
        'runner-vm started',
      ]),
    );
    expect(lifetime, isNot(contains('inventory checked')));
  });

  test('a host write outside the allowlist fails the run once the suites '
      'pass', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      inventoryCheckExit: '7',
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      7,
      reason: '$output',
    );
    expect(
      fixtureLifetime(),
      containsAllInOrder(['inventory started', 'inventory checked']),
    );
  });

  test('run.sh exits with the runner-VM leg\'s status once the suites '
      'pass', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      runnerVmExit: '4',
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      4,
      reason: '$output',
    );
    expect(
      fixtureLifetime(),
      containsAllInOrder(['suites started', 'runner-vm started']),
    );
  });

  test('a signal during the runner-VM leg stops it before the fixture '
      'goes', () async {
    final (:process, :exitCode, :output) = await startRun(
      suitesExit: '0',
      holdRunnerVm: true,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!log.readAsLinesSync().contains('runner-vm started')) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The runner-VM leg never started:\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    process.kill();
    final status = await exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        fail('run.sh did not exit:\n$output');
      },
    );
    expect(status, isNot(0), reason: '$output');
    expect(
      fixtureLifetime(),
      contains('runner-vm stopped'),
      reason: 'run.sh did not stop the runner-VM leg before compose down',
    );
  });

  test('run.sh exits with the soak\'s status once the legs before it '
      'pass', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      soakExit: '5',
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      5,
      reason: '$output',
    );
    expect(
      fixtureLifetime(),
      containsAllInOrder([
        'suites started',
        'runner-vm started',
        'soak started',
      ]),
    );
  });

  test('run.sh seeds the Docker host before the suites, with the image '
      'it loaded', () async {
    final (process: _, :exitCode, :output) = await startRun(suitesExit: '0');

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      0,
      reason: '$output',
    );
    // `docker save` and the `docker load` it pipes into start together,
    // so their stubs log in either order.
    expect(
      fixtureLifetime(),
      containsAllInOrder([
        startsWith('docker pull --quiet mirror.gcr.io/library/busybox:'),
        startsWith('docker save '),
      ]),
    );
    expect(
      fixtureLifetime(),
      containsAllInOrder([
        startsWith('docker pull --quiet mirror.gcr.io/library/busybox:'),
        allOf(
          startsWith('ssh '),
          endsWith(' klab@127.0.0.1 docker load --quiet'),
        ),
        allOf(
          startsWith('ssh '),
          endsWith(' klab@127.0.0.1 sh -s -- sha256:stub'),
        ),
        'suites started',
      ]),
    );
  });

  test('run.sh passes when every leg passes and the soak left its '
      'numbers', () async {
    final (process: _, :exitCode, :output) = await startRun(suitesExit: '0');

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      0,
      reason: '$output',
    );
    // Outside GitHub Actions the soak is a one-minute smoke run, and its
    // numbers go under build/ by an absolute path.
    expect(
      log.readAsLinesSync(),
      contains(
        'soak seconds 60 dir '
        '${sandbox.path}/klabautermann/build/integration-evidence/soak',
      ),
    );
  });

  test('the soak runs ten minutes on GitHub Actions, into the evidence '
      'directory', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      environment: {
        'GITHUB_ACTIONS': 'true',
        'KLABAUTERMANN_EVIDENCE_DIR': '${sandbox.path}/evidence',
      },
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      0,
      reason: '$output',
    );
    expect(
      log.readAsLinesSync(),
      contains('soak seconds 600 dir ${sandbox.path}/evidence/soak'),
    );
  });

  test('a soak that passes without soak.json fails the run, since it '
      'skipped', () async {
    final (process: _, :exitCode, :output) = await startRun(
      suitesExit: '0',
      soakEvidence: false,
    );

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      1,
      reason: '$output',
    );
    expect('$output', contains('it skipped'));
  });

  test('a signal during the soak stops it before the fixture goes', () async {
    final (:process, :exitCode, :output) = await startRun(
      suitesExit: '0',
      holdSoak: true,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!log.readAsLinesSync().contains('soak started')) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The soak never started:\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    process.kill();
    final status = await exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        fail('run.sh waited for the soak to finish:\n$output');
      },
    );
    expect(status, isNot(0), reason: '$output');
    expect(
      fixtureLifetime(),
      contains('soak stopped'),
      reason: 'run.sh did not stop the soak before compose down',
    );
  });

  test('a soak length that is not a whole number stops run.sh before the '
      'fixture starts', () async {
    final result = await Process.run(
      'bash',
      [run.path],
      environment: {
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'TMPDIR': sandbox.path,
        'STUB_LOG': log.path,
        'KLABAUTERMANN_SOAK_SECONDS': '10m',
      },
      includeParentEnvironment: false,
    );

    expect(result.exitCode, 64, reason: '${result.stderr}');
    expect('${result.stderr}', contains('KLABAUTERMANN_SOAK_SECONDS'));
    expect(log.existsSync(), isFalse, reason: 'run.sh called Docker');
  });
}

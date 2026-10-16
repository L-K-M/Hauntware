// How run.sh ends (03 §11.3, D53), checked without Docker: a copy of it
// runs with stand-ins for Docker, OpenSSH and Dart.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The copy takes its own lock, so the test neither waits for nor blocks
/// a real fixture run on this machine.
const _lockLine = "readonly lock_file='/tmp/klabautermann-fixture.lock'";

/// Bodies of the stand-ins, which log to `$STUB_LOG`. The suites keep
/// their PID in `$STUB_SUITES_PID` while they run, and exit with
/// `$STUB_SUITES_EXIT` when it is set, or otherwise once a SIGTERM stops
/// them.
const _stubs = {
  'docker': r'''
echo "docker $*" >>"$STUB_LOG"
if [[ "$*" == *' port '* ]]; then echo '127.0.0.1:49152'; fi
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
if [[ "$1" == -s ]]; then echo 'SSH_AGENT_PID=0; export SSH_AGENT_PID;'; fi
''',
  'ssh-add': '',
  'dart': r'''
if [[ "$1" == run ]]; then cat >/dev/null; exit 0; fi
echo "$$" >"$STUB_SUITES_PID"
trap 'rm -f -- "$STUB_SUITES_PID"' EXIT
trap 'echo "suites stopped" >>"$STUB_LOG"; exit 143' TERM
echo 'suites started' >>"$STUB_LOG"
if [[ -n "${STUB_SUITES_EXIT:-}" ]]; then exit "$STUB_SUITES_EXIT"; fi
for ((i = 0; i < 300; i++)); do sleep 0.1; done
''',
};

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
    final chmod = await Process.run('chmod', [
      '+x',
      for (final name in _stubs.keys) '${bin.path}/$name',
    ]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
  });

  /// Starts the copy, and completes once the suites have started.
  Future<({Process process, Future<int> exitCode, StringBuffer output})>
  startRun({String? suitesExit}) async {
    final process = await Process.start(
      'bash',
      [run.path],
      environment: {
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
        'TMPDIR': sandbox.path,
        'STUB_LOG': log.path,
        'STUB_SUITES_PID': suitesPid.path,
        'STUB_SUITES_EXIT': ?suitesExit,
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
    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      isNot(0),
      reason: '$output',
    );
    expect(
      fixtureLifetime(),
      contains('suites stopped'),
      reason: 'run.sh did not stop the suites before compose down',
    );
  });

  test('run.sh exits with the suites\' status after teardown', () async {
    final (process: _, :exitCode, :output) = await startRun(suitesExit: '3');

    expect(
      await exitCode.timeout(const Duration(seconds: 20)),
      3,
      reason: '$output',
    );
    // Its expectations check that teardown ran after the suites.
    fixtureLifetime();
  });
}

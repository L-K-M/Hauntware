@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'fixture_process.dart';

const _deadline = Duration(seconds: 1);
const _observationTimeout = Duration(seconds: 5);
const _pollInterval = Duration(milliseconds: 20);
const _commandFailureExitCode = 42;
const _processFailsafe = Duration(seconds: 30);

void main() {
  test('deadline terminates the command and its child', () async {
    final command = await _HangingCommand._create(_TermBehavior.exit);
    final result = await command._run();

    await command._expectStopped();
    expect(result, isA<ProcessResult>());
    expect(
      (result as ProcessResult).exitCode,
      -ProcessSignal.sigkill.signalNumber,
    );
    expect(result.stdout, contains('fixture started'));
    expect(result.stderr, contains('fixture diagnostic'));
  });

  test('deadline kills a child that ignores TERM', () async {
    final command = await _HangingCommand._create(_TermBehavior.ignore);
    final result = await command._run();

    await command._expectStopped();
    expect(result, isA<ProcessResult>());
    expect(
      (result as ProcessResult).exitCode,
      -ProcessSignal.sigkill.signalNumber,
    );
    expect(result.stdout, contains('fixture started'));
    expect(result.stderr, contains('fixture diagnostic'));
  });

  test('the deadline does not depend on the Dart event loop', () async {
    final command = await _HangingCommand._create(_TermBehavior.exit);
    final pending = command._run();
    final childPid = await command._waitForChildPid();

    sleep(_deadline * 2);
    final stoppedDuringPause = !_isRunning(childPid);
    final result = await pending;

    await command._expectStopped();
    expect(result, isA<ProcessResult>());
    expect(stoppedDuringPause, isTrue);
  });

  test('a very short deadline still stops the launched command', () async {
    final result = await runFixtureProcess('sleep', [
      '${_processFailsafe.inSeconds}',
    ], timeout: const Duration(microseconds: 1)).timeout(_observationTimeout);

    expect(result.exitCode, -ProcessSignal.sigkill.signalNumber);
  });

  test(
    'cleanup survives an empty PID file and stops the remaining process',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fixture-cleanup-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final process = await Process.start('sleep', [
        '${_processFailsafe.inSeconds}',
      ]);
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      });
      await File('${directory.path}/child.pid').writeAsString('');
      await File(
        '${directory.path}/parent.pid',
      ).writeAsString('${process.pid}');

      await _HangingCommand(directory)._dispose();

      expect(
        await process.exitCode.timeout(_observationTimeout),
        -ProcessSignal.sigkill.signalNumber,
      );
      expect(await directory.exists(), isFalse);
    },
  );

  for (final timeout in [Duration.zero, -_deadline]) {
    test('rejects $timeout before launching an unbounded process', () {
      expect(
        () => runFixtureProcess('must-not-start', [], timeout: timeout),
        throwsArgumentError,
      );
    });
  }

  for (final signal in [
    ProcessSignal.sigterm,
    ProcessSignal.sigkill,
    ProcessSignal.sigint,
    ProcessSignal.sigpipe,
  ]) {
    test('preserves a command terminated by ${signal.signalNumber}', () async {
      final result = await runFixtureProcess('/bin/bash', [
        '-c',
        'kill -${signal.signalNumber} "\$\$"',
      ], timeout: _observationTimeout);
      expect(result.exitCode, -signal.signalNumber);
    });
  }

  test('closes stdin before waiting for the command', () async {
    final result = await runFixtureProcess('/bin/bash', [
      '-c',
      'if read -r value; then exit 42; fi; printf EOF',
    ], timeout: _deadline);
    expect(result.exitCode, 0);
    expect(result.stdout, 'EOF');
  });

  test('reports an executable that does not exist', () async {
    final result = await runFixtureProcess(
      'missing-hauntware-fixture-executable',
      [],
      timeout: _observationTimeout,
    );
    expect(result.exitCode, 127);
    expect(result.stderr, contains('missing-hauntware-fixture-executable'));
  });

  test('distinguishes a numeric exit code from signal termination', () async {
    final result = await runFixtureProcess('/bin/bash', [
      '-c',
      'exit 137',
    ], timeout: _observationTimeout);
    expect(result.exitCode, 137);
  });

  test(
    'preserves exit status, output, arguments, environment and cwd',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fixture-result-',
      );
      addTearDown(() => directory.delete(recursive: true));
      for (final module in ['subprocess', 'signal']) {
        await File(
          '${directory.path}/$module.py',
        ).writeAsString("raise RuntimeError('untrusted monitor module')\n");
      }
      const argument = r'a path; $(must-not-run)';
      final result = await runFixtureProcess(
        'bash',
        [
          '-c',
          r'printf "%s\n%s\n%s\n" "$1" "$FIXTURE_VALUE" "$PWD"; '
              'printf "diagnostic" >&2; exit $_commandFailureExitCode',
          'fixture',
          argument,
        ],
        timeout: _observationTimeout,
        environment: {
          'FIXTURE_VALUE': 'inherited fixture value',
          'PYTHONPATH': directory.path,
        },
        workingDirectory: directory.path,
      );

      expect(result.exitCode, _commandFailureExitCode);
      expect(
        result.stdout,
        '$argument\ninherited fixture value\n${directory.path}\n',
      );
      expect(result.stderr, 'diagnostic');
    },
  );
}

enum _TermBehavior { exit, ignore }

/// Records both PIDs for cleanup after a failed regression assertion.
class _HangingCommand {
  final Directory _directory;

  _HangingCommand(this._directory);

  static Future<_HangingCommand> _create(_TermBehavior behavior) async {
    final command = _HangingCommand(
      await Directory.systemTemp.createTemp('fixture-deadline-'),
    );
    addTearDown(command._dispose);
    final trap = behavior == _TermBehavior.ignore ? "trap '' TERM\n" : '';
    await File('${command._directory.path}/parent.sh').writeAsString('''
printf '%s' "\$\$" > parent.pid
printf 'fixture started\\n'
printf 'fixture diagnostic\\n' >&2
bash child.sh &
wait "\$!"
''');
    await File('${command._directory.path}/child.sh').writeAsString('''
$trap
printf '%s' "\$\$" > child.pid
exec sleep ${_processFailsafe.inSeconds}
''');
    return command;
  }

  Future<Object> _run() async {
    try {
      return await runFixtureProcess(
        'bash',
        ['${_directory.path}/parent.sh'],
        timeout: _deadline,
        workingDirectory: _directory.path,
      ).timeout(_observationTimeout);
    } on TimeoutException catch (error) {
      // Inspect surviving PIDs before reporting a deadline regression.
      return error;
    }
  }

  Future<int> _waitForChildPid() async {
    final file = File('${_directory.path}/child.pid');
    final clock = Stopwatch()..start();
    while (clock.elapsed < _observationTimeout) {
      if (await file.exists()) {
        final pid = int.tryParse(await file.readAsString());
        if (pid != null) return pid;
      }
      await Future<void>.delayed(_pollInterval);
    }
    throw TimeoutException('The fixture child did not start.');
  }

  Future<void> _expectStopped() async {
    for (final name in ['child', 'parent']) {
      final pid = int.parse(
        await File('${_directory.path}/$name.pid').readAsString(),
      );
      final clock = Stopwatch()..start();
      while (_isRunning(pid) && clock.elapsed < _deadline) {
        await Future<void>.delayed(_pollInterval);
      }
      expect(
        _isRunning(pid),
        isFalse,
        reason: '$name PID $pid survives the deadline',
      );
    }
  }

  Future<void> _dispose() async {
    for (final name in ['child', 'parent']) {
      final file = File('${_directory.path}/$name.pid');
      if (!await file.exists()) continue;

      // A deadline can interrupt the PID write; never signal a process group.
      final pid = int.tryParse(await file.readAsString());
      if (pid == null || pid <= 0) continue;

      Process.killPid(pid, ProcessSignal.sigkill);
    }
    await _directory.delete(recursive: true);
  }
}

bool _isRunning(int pid) {
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    // An unreaped zombie cannot execute a late Docker lifecycle operation.
    return !{'Z', 'X'}.contains(
      stat.substring(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3),
    );
  } on FileSystemException {
    return false;
  }
}

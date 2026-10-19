// Spike S3's elevation matrix (03 §8.3; M4 plan E01), driven by
// test/integration/capture_elevation.sh through capture.sh
// --elevation-only. It runs on the host, beside Docker, not in the
// container: the container needs no Dart runtime, so Alpine's musl is no
// obstacle.
//
// Run from klabautermann/packages/klabautermann_core:
//
//   dart run tool/capture_elevation.dart run --container <name>
//       --user <account> --case <name> --description <text>
//       --password-file <path> --out <file.json>
//   dart run tool/capture_elevation.dart check <committed dir> <captured dir>
//
// run drives one case (tool/src/elevation_matrix.dart). Each command runs
// as `docker exec -i -u <account> <container>` under `sh -c`, as sshd
// runs a login shell's command, in a new session with no controlling
// terminal: the wrapper backgrounds `setsid`, so `setsid` is no process
// group leader and calls setsid(2) in place without forking, in
// util-linux and BusyBox alike, and hands its own stdin through fd 3,
// since a backgrounded command's stdin is otherwise /dev/null. The
// password file's first line is the account's password; it reaches the
// container only on stdin.
//
// check compares every case file of the committed directory with the new
// capture's (compareElevationCases) and exits 1 on a difference or a
// missing case.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:seance_core/seance_core.dart' show RemoteCommandResult;

import 'src/elevation_matrix.dart';

/// Starts the command in a new session without a tty, its stdin intact.
const _sessionWrapper = r'exec 3<&0; setsid "$@" <&3 3<&- & wait "$!"';

/// Bounds one command; a prompt that waits on a tty would hang otherwise.
const _commandTimeout = Duration(seconds: 60);

const _runOptions = {
  'container',
  'user',
  'case',
  'description',
  'password-file',
  'out',
};

Future<void> main(List<String> args) async {
  switch (args) {
    case ['run', ...final rest]:
      await _run(rest);
    case ['check', final committed, final captured]:
      _check(committed, captured);
    default:
      _usage('expected run or check');
  }
}

Future<void> _run(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (!_runOptions.contains(name) || i + 1 >= args.length) {
      _usage('unexpected argument ${args[i]}');
    }
    options[name] = args[++i];
  }
  final missing = _runOptions.difference(options.keys.toSet());
  if (missing.isNotEmpty) _usage('missing --${missing.join(', --')}');

  final password = const LineSplitter()
      .convert(File(options['password-file']!).readAsStringSync())
      .firstOrNull;
  if (password == null || password.isEmpty) {
    _usage('the password file has no first line');
  }

  final evidence = await runElevationCase(
    name: options['case']!,
    description: options['description']!,
    runner: (command, stdin) =>
        _dockerExec(options['container']!, options['user']!, command, stdin),
    password: password,
    wrongPassword: _randomHex(),
  );
  File(options['out']!)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    );
}

Future<RemoteCommandResult> _dockerExec(
  String container,
  String user,
  String command,
  List<int> stdin,
) async {
  final process = await Process.start('docker', [
    'exec',
    '-i',
    '-u',
    user,
    container,
    'sh',
    '-c',
    _sessionWrapper,
    'sh',
    'sh',
    '-c',
    command,
  ]);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  // A command that exits without reading closes the pipe first; what it
  // did not read is part of its result, not an error here.
  process.stdin.add(stdin);
  await process.stdin.close().catchError((Object _) {});
  final exitCode = await process.exitCode.timeout(
    _commandTimeout,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw StateError('"$command" did not finish in $_commandTimeout');
    },
  );
  return RemoteCommandResult(
    stdout: await stdout,
    stderr: await stderr,
    exitCode: exitCode,
  );
}

void _check(String committedDir, String capturedDir) {
  final committed = Directory(committedDir);
  if (!committed.existsSync()) _usage('$committedDir does not exist');
  final cases = committed
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();
  if (cases.isEmpty) _usage('$committedDir has no case files');

  var differs = false;
  for (final file in cases) {
    final name = file.uri.pathSegments.last;
    final captured = File('$capturedDir/$name');
    if (!captured.existsSync()) {
      stderr.writeln('$name: not captured');
      differs = true;
      continue;
    }
    final differences = compareElevationCases(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
      jsonDecode(captured.readAsStringSync()) as Map<String, Object?>,
    );
    for (final line in differences) {
      stderr.writeln('$name: $line');
    }
    differs |= differences.isNotEmpty;
  }
  if (differs) exit(1);
}

String _randomHex() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 24; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

Never _usage(String message) {
  stderr
    ..writeln('capture_elevation: $message')
    ..writeln(
      'usage: capture_elevation.dart run --container <name> --user <account> '
      '--case <name> --description <text> --password-file <path> '
      '--out <file.json>',
    )
    ..writeln(
      '       capture_elevation.dart check <committed dir> <captured dir>',
    );
  exit(2);
}

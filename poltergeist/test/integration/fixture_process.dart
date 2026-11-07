import 'dart:async';
import 'dart:io';

/// Bounds a Linux command's process group until that command exits.
///
/// Callers must wait for their children, as service-control.sh does. Detached
/// descendants and children outliving the command are outside this deadline.
///
/// Dart reports SIGKILL as -9 (shells use 137); the outer harness owns Docker
/// cleanup when the command exceeds its deadline.
Future<ProcessResult> runFixtureProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
  }

  // util-linux setsid execs this fresh child in its own process group.
  // Unlike GNU timeout, uutils timeout can leave grandchildren running when
  // asked to send KILL. Own the deadline instead of relying on that behavior.
  return Process.start(
    'setsid',
    [executable, ...arguments],
    environment: environment,
    workingDirectory: workingDirectory,
  ).then((process) {
    final deadline = Timer(timeout, () {
      // Linux kill(2) interprets a negative PID as a process-group ID. A very
      // short deadline can precede setsid's setup, so also stop the child if
      // its group does not exist yet.
      if (!Process.killPid(-process.pid, ProcessSignal.sigkill)) {
        process.kill(ProcessSignal.sigkill);
      }
    });
    return Future.wait<Object>([
      process.exitCode.whenComplete(deadline.cancel),
      process.stdout.transform(systemEncoding.decoder).join(),
      process.stderr.transform(systemEncoding.decoder).join(),
    ]).then(
      (values) => ProcessResult(
        process.pid,
        values[0] as int,
        values[1] as String,
        values[2] as String,
      ),
    );
  });
}

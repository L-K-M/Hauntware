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

  // uutils timeout can leave grandchildren running when asked to send KILL.
  // Keep the monitor outside Dart so a blocked test isolate cannot postpone
  // the deadline. The monitor creates and owns the command's process group.
  // Isolate monitor imports from the command's cwd and Python environment.
  final seconds = timeout.inMicroseconds / Duration.microsecondsPerSecond;
  return Process.run(
    'python3',
    ['-I', '-S', '-c', _monitorScript, '$seconds', executable, ...arguments],
    environment: environment,
    workingDirectory: workingDirectory,
  );
}

const _monitorScript = r'''
import errno
import os
import signal
import subprocess
import sys

os.setsid()

def stop_group(*_):
    os.killpg(os.getpgrp(), signal.SIGKILL)

for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
    signal.signal(signum, stop_group)

try:
    child = subprocess.Popen(sys.argv[2:])
except OSError as error:
    print(error, file=sys.stderr)
    sys.exit(127 if error.errno == errno.ENOENT else 126)

try:
    status = child.wait(timeout=float(sys.argv[1]))
except subprocess.TimeoutExpired:
    stop_group()

if status < 0:
    signum = -status
    if signum not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
sys.exit(status)
''';

// An SshLink double that runs each command through a local login shell,
// as sshd hands an exec request to the account's shell (`<shell> -c`).
import 'dart:async';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import 'scripted_link.dart';

/// `/bin/<name>` or `/usr/bin/<name>`, or null when not installed.
String? localShell(String name) {
  for (final dir in ['/bin', '/usr/bin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Runs commands with [shell] as the login shell, and as the `sh` the
/// sampler's `env ... sh -s` finds on `PATH`: a directory holding an `sh`
/// link to [shell] goes first on the commands' `PATH`, so the start
/// command runs verbatim. bash started as `sh` runs in POSIX mode, as it
/// does where `/bin/sh` is bash.
final class LocalProcessLink extends TestLinkBase {
  LocalProcessLink._(this.shell, this._shim, this.startupOutput);

  /// [startupOutput] is printed before each command runs, as a login
  /// shell's startup files may.
  static Future<LocalProcessLink> create(
    String shell, {
    String startupOutput = '',
  }) async {
    final shim = await Directory.systemTemp.createTemp('klab-sh-');
    await Link('${shim.path}/sh').create(shell);
    return LocalProcessLink._(shell, shim, startupOutput);
  }

  final String shell;
  final Directory _shim;
  final String startupOutput;
  final processes = <LocalRemoteProcess>[];

  /// The working directory of every command.
  Directory get workingDirectory => _shim;

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) async {
    final prefix = startupOutput.isEmpty
        ? ''
        : 'printf %s ${quoteShellWord(startupOutput)}; ';
    final p = await Process.start(
      shell,
      ['-c', '$prefix$command'],
      workingDirectory: _shim.path,
      environment: {
        'PATH': '${_shim.path}:${Platform.environment['PATH'] ?? ''}',
      },
    );
    final remote = LocalRemoteProcess(p);
    processes.add(remote);
    return remote;
  }

  /// Kills what is still running and removes the `sh` link.
  Future<void> dispose() async {
    for (final p in processes) {
      await p.close();
    }
    await _shim.delete(recursive: true);
  }
}

/// A local [Process] as a [RemoteProcess]. [close] sends TERM like
/// `SshRemoteProcess.close`, then KILL after [closeBound], because a
/// stopped process holds TERM until it continues.
final class LocalRemoteProcess implements RemoteProcess {
  LocalRemoteProcess(
    this._process, {
    this.closeBound = const Duration(seconds: 2),
  }) : exit = _process.exitCode.then(
         (code) => code < 0
             ? RemoteExit(exitSignal: '${-code}')
             : RemoteExit(exitCode: code),
       ) {
    // A write after the process ended fails `done`; the sampler sees the
    // exit instead.
    unawaited(_process.stdin.done.then((_) {}, onError: (Object _) {}));
  }

  final Process _process;
  final Duration closeBound;

  int get pid => _process.pid;

  @override
  final Future<RemoteExit> exit;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  StreamSink<List<int>> get stdin => _process.stdin;

  @override
  void signal(RemoteSignal signal) => _process.kill(switch (signal) {
    RemoteSignal.term => ProcessSignal.sigterm,
    RemoteSignal.kill => ProcessSignal.sigkill,
    _ => throw UnsupportedError('$signal'),
  });

  @override
  Future<void> close() async {
    signal(RemoteSignal.term);
    unawaited(_process.stdin.close().then((_) {}, onError: (Object _) {}));
    try {
      await exit.timeout(closeBound);
    } on TimeoutException {
      signal(RemoteSignal.kill);
      await exit;
    }
  }
}

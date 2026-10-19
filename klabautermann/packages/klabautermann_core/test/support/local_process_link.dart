// An SshLink double that runs each command through a local login shell,
// as sshd hands an exec request to the account's shell (`<shell> -c`).
import 'dart:async';
import 'dart:convert';
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

  /// [command] to its end, as `SshLink.run` collects an exec channel.
  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    final p = await start(command);
    final stdout = utf8.decodeStream(p.stdout);
    final stderr = utf8.decodeStream(p.stderr);
    p.stdin.add(stdin ?? const []);
    await p.stdin.close();
    final exit = await p.exit;
    return RemoteCommandResult(
      exitCode: exit.exitCode,
      stdout: await stdout,
      stderr: await stderr,
    );
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
  late final StreamSink<List<int>> stdin = _RecordingSink(
    _process.stdin,
    _written,
  );
  final List<int> _written = [];

  /// Everything written to stdin, such as a sampler's program.
  String get written => utf8.decode(_written, allowMalformed: true);

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

/// Passes writes on to [_sink] and keeps a copy in [_written].
final class _RecordingSink implements StreamSink<List<int>> {
  _RecordingSink(this._sink, this._written);

  final StreamSink<List<int>> _sink;
  final List<int> _written;

  @override
  void add(List<int> data) {
    _written.addAll(data);
    _sink.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> get done => _sink.done;
}

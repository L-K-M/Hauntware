/// Local HWS/1 sampler runs for the capture tool (03 §6.2, §6.5).
///
/// Starts the real program on this machine, in one of the two ways a host
/// starts it, and drives it one request at a time as the engine does: the
/// program first, nothing else until READY, then at most one outstanding
/// request (03 §6.2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';

/// PATH for local runs, fixed so that the probe's tool paths and the
/// `sh` the start command execs do not depend on the caller's
/// environment.
const kCapturePath =
    '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

/// The first [name] on [kCapturePath], or null.
String? findOnCapturePath(String name) => [
  for (final dir in kCapturePath.split(':')) '$dir/$name',
].where((p) => File(p).existsSync()).firstOrNull;

/// The environment a local run gets instead of the caller's. With
/// [ssh] it carries `SSH_CLIENT` and `SSH_CONNECTION`, which sshd sets
/// for a session (OpenSSH `session.c`, `do_setup_env`), with
/// documentation addresses. `SHLVL` is never set: with `SHLVL=1`, bash
/// 5.2.21 on Ubuntu 24.04 skipped `~/.bashrc` under `bash -c` even with
/// `SSH_CLIENT` set, which would hide the startup-file output.
Map<String, String> runEnvironment({
  required String home,
  required String user,
  String? shell,
  bool ssh = false,
}) => {
  'HOME': home,
  'PATH': kCapturePath,
  'USER': user,
  'LOGNAME': user,
  'SHELL': ?shell,
  if (ssh) ...{
    'SSH_CLIENT': '192.0.2.1 50000 22',
    'SSH_CONNECTION': '192.0.2.1 50000 192.0.2.2 22',
  },
};

/// The environment words of [kSamplerStartCommand]: everything between
/// `exec` and the trailing `sh -s`.
List<String> _startEnvWords() {
  final words = kSamplerStartCommand.split(' ');
  if (words.first != 'exec' ||
      words.length < 4 ||
      words[words.length - 2] != 'sh' ||
      words.last != '-s') {
    throw StateError('unexpected start command: $kSamplerStartCommand');
  }
  return words.sublist(1, words.length - 2);
}

/// [shell]'s basename, which a login launch passes as argv[0] and the
/// child looks up on [kCapturePath]; that lookup must find [shell].
String _loginArgv0(String shell) {
  final name = shell.substring(shell.lastIndexOf('/') + 1);
  final found = findOnCapturePath(name);
  if (found == null ||
      File(found).resolveSymbolicLinksSync() !=
          File(shell).resolveSymbolicLinksSync()) {
    throw ArgumentError.value(
      shell,
      'shell',
      'is not the first $name on $kCapturePath',
    );
  }
  return name;
}

enum _LaunchMode { stdinShell, loginShell }

/// How the tool starts a sampler.
final class SamplerLaunch {
  /// `<shell> -s` under the start command's environment (the start line
  /// with [shell] in place of `sh`), with no login shell in front. The
  /// shell runs through a link named `sh`, as the start line runs
  /// `/bin/sh`: bash then enters POSIX mode and zsh sh emulation, since
  /// both choose from argv[0]'s basename. `$0` is the link's path.
  const SamplerLaunch.stdinShell(this.shell) : _mode = _LaunchMode.stdinShell;

  /// `<login shell> -c '<start command>'`, the argv sshd gives a session
  /// command, with the shell's basename as argv[0] (OpenSSH `session.c`,
  /// `do_child`): the login shell runs its startup files and execs the
  /// `sh` found on [kCapturePath]. The child finds [shell] by that
  /// basename on [kCapturePath], so it must be the first there.
  const SamplerLaunch.loginShell(this.shell) : _mode = _LaunchMode.loginShell;

  /// The shell's path.
  final String shell;
  final _LaunchMode _mode;

  /// The command line as a fixture's SOURCE.md names it.
  String get label => switch (_mode) {
    _LaunchMode.stdinShell => '$shell -s',
    _LaunchMode.loginShell => "$shell -c '$kSamplerStartCommand'",
  };
}

/// The session could not start or continue.
final class SamplerFailure implements Exception {
  const SamplerFailure(this.fault, this.detail);

  /// The assembler's fault, or null when the process exited first.
  final HwsSessionFault? fault;
  final String detail;

  @override
  String toString() => 'SamplerFailure(${fault?.name ?? 'exit'}): $detail';
}

/// One answered request.
final class SamplerReply {
  const SamplerReply(
    this.tick,
    this.lostDetail,
    this.bytes,
    this.head,
    this.wall,
  );

  /// The assembled reply, or null when it was lost to a framing error
  /// ([lostDetail] says why).
  final HwsTick? tick;
  final String? lostDetail;

  /// Every stdout byte of the reply, from `B` through the `E` line.
  final int bytes;

  /// The reply's first KiB, where a section's declared size can be read
  /// even when the reply was lost.
  final Uint8List head;

  /// From writing the request line to reading its `E` marker.
  final Duration wall;
}

/// CPU time of [pid] in clock ticks, read from `/proc/<pid>/stat`
/// (proc_pid_stat(5)): its own (`utime` + `stime`, fields 14 and 15) and
/// that of its waited-for children (`cutime` + `cstime`, 16 and 17).
({int self, int children}) readProcessCpu(int pid) {
  final text = File('/proc/$pid/stat').readAsStringSync();
  // Field 2 (comm) may hold spaces and parentheses; it ends at the last
  // `)`, and field 3 starts after the following space.
  final fields = text.substring(text.lastIndexOf(')') + 2).split(' ');
  int field(int n) => int.parse(fields[n - 3]);
  return (self: field(14) + field(15), children: field(16) + field(17));
}

/// Clock ticks per second for [readProcessCpu] (`getconf CLK_TCK`).
Future<int> clockTicksPerSecond() async {
  final r = await Process.run('getconf', ['CLK_TCK']);
  final value = int.tryParse(r.stdout.toString().trim());
  if (r.exitCode != 0 || value == null || value <= 0) {
    throw StateError('getconf CLK_TCK failed: ${r.stderr}');
  }
  return value;
}

/// A sampler process on this machine.
final class LocalSampler {
  LocalSampler._(this._process, String nonce, this._shDir)
    : _assembler = HwsTickAssembler(nonce: nonce),
      _firstMarker = '\x1e$nonce SELF ' {
    // The shell can exit, and fail [_ready], while [start] is still
    // writing the program and before any caller listens; without this
    // the failure would also surface as an uncaught error. Listeners
    // added later through [ready] still receive it.
    _ready.future.ignore();
  }

  static const _rawPrefixCap = 1 << 20;
  static const _headBytes = 1024;
  static const _exitTimeout = Duration(seconds: 30);

  final Process _process;

  /// Holds the `sh` link of a stdin launch until [close].
  final Directory? _shDir;
  final HwsTickAssembler _assembler;
  final String _firstMarker;
  final _ready = Completer<void>();
  final _stderr = StringBuffer();
  final _rawPrefix = BytesBuilder(copy: false);
  late final Future<void> _stdoutDone;

  bool _exited = false;
  Completer<SamplerReply>? _pending;
  int _pendingSeq = 0;
  int _pendingBytes = 0;
  final _pendingHead = BytesBuilder();
  final _pendingWatch = Stopwatch();

  /// Starts [launch] with [environment] only (no parent variables),
  /// whose PATH must be [kCapturePath], and writes the [kind] program.
  /// Await [ready] before [request], and [close] in any case.
  static Future<LocalSampler> start(
    SamplerLaunch launch, {
    required SamplerKind kind,
    required Map<String, String> environment,
  }) async {
    if (environment['PATH'] != kCapturePath) {
      throw ArgumentError.value(
        environment['PATH'],
        'environment',
        'PATH must be $kCapturePath',
      );
    }
    final nonce = generateNonce(Random.secure());
    Directory? shDir;
    final List<String> argv;
    switch (launch._mode) {
      case _LaunchMode.stdinShell:
        shDir = Directory.systemTemp.createTempSync('klab-sh-');
        // A relative link target resolves from the link's directory, not
        // from the cwd that [launch]'s path is relative to.
        final sh = Link('${shDir.path}/sh')
          ..createSync(File(launch.shell).absolute.path);
        argv = [..._startEnvWords(), sh.path, '-s'];
      case _LaunchMode.loginShell:
        argv = [_loginArgv0(launch.shell), '-c', kSamplerStartCommand];
    }
    final Process process;
    try {
      // Without a slash in argv.first the child looks it up on its own
      // PATH, and argv[0] stays the bare name.
      process = await Process.start(
        argv.first,
        argv.sublist(1),
        environment: environment,
        includeParentEnvironment: false,
      );
    } on Object {
      shDir?.deleteSync(recursive: true);
      rethrow;
    }
    final sampler = LocalSampler._(process, nonce, shDir).._listen();
    // A shell that exits early breaks the pipe; that failure reaches the
    // caller through [ready] or [request] with the shell's stderr.
    unawaited(process.stdin.done.then<void>((_) {}, onError: (_) {}));
    process.stdin.write(buildSamplerProgram(kind: kind, nonce: nonce));
    await process.stdin.flush().catchError((_) {});
    return sampler;
  }

  /// The sampler shell's pid. Both launches exec into the shell, so this
  /// is the process whose CPU [readProcessCpu] reads.
  int get pid => _process.pid;

  /// Completes at READY; fails with [SamplerFailure].
  Future<void> get ready => _ready.future;

  /// Output before the program's first marker, `SELF` just before READY,
  /// from the start of stdout; null when no `SELF` marker arrived within
  /// the first MiB.
  int? get bytesBeforeReady {
    final at = latin1.decode(_rawPrefix.toBytes()).indexOf(_firstMarker);
    return at < 0 ? null : at;
  }

  /// Sends `hw_t <seq> <collectors>` and waits for its reply.
  Future<SamplerReply> request(int seq, List<Collector> collectors) {
    if (_pending != null) throw StateError('one request at a time');
    if (_exited) {
      return Future.error(SamplerFailure(null, 'shell exited: $_stderr'));
    }
    final pending = _pending = Completer<SamplerReply>();
    _pendingSeq = seq;
    _pendingBytes = 0;
    _pendingHead.clear();
    _pendingWatch
      ..reset()
      ..start();
    _process.stdin.write(encodeTickRequest(seq, collectors));
    return pending.future;
  }

  /// Closes stdin, waits for the shell to exit (killing it after 30 s)
  /// and returns its stderr.
  Future<String> close() async {
    await _process.stdin.close().catchError((_) {});
    await _process.exitCode.timeout(
      _exitTimeout,
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    await _stdoutDone;
    _shDir?.deleteSync(recursive: true);
    return _stderr.toString();
  }

  void _listen() {
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_stderr.write);
    _stdoutDone = _process.stdout.listen(_onBytes).asFuture<void>().then((_) {
      _exited = true;
      _failAll(null, 'shell exited; stderr: ${_stderr.toString().trim()}');
    });
  }

  void _onBytes(List<int> chunk) {
    if (_rawPrefix.length < _rawPrefixCap) _rawPrefix.add(chunk);
    if (_pending != null) {
      _pendingBytes += chunk.length;
      if (_pendingHead.length < _headBytes) {
        final room = _headBytes - _pendingHead.length;
        _pendingHead.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
      }
    }
    for (final e in _assembler.push(chunk)) {
      switch (e) {
        case HwsSessionReady():
          if (!_ready.isCompleted) _ready.complete();
        case HwsTick(:final seq) when _pending != null && seq == _pendingSeq:
          _answer(e, null);
        case HwsTickLost(:final seq, :final detail)
            when _pending != null && seq == _pendingSeq:
          _answer(null, detail);
        case HwsTick() || HwsTickLost():
          // Not the pending request's reply; with one request at a time
          // the program sends none.
          break;
        case HwsSessionFailed(:final fault, :final detail):
          _failAll(fault, detail);
      }
    }
  }

  void _answer(HwsTick? tick, String? lostDetail) {
    final pending = _pending!;
    _pending = null;
    _pendingWatch.stop();
    pending.complete(
      SamplerReply(
        tick,
        lostDetail,
        _pendingBytes,
        _pendingHead.toBytes(),
        _pendingWatch.elapsed,
      ),
    );
  }

  void _failAll(HwsSessionFault? fault, String detail) {
    final failure = SamplerFailure(fault, detail);
    if (!_ready.isCompleted) _ready.completeError(failure);
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(failure);
    }
  }
}

/// Privilege elevation over an [SshLink] (03-ARCHITECTURE.md §8.3, D24;
/// seance-core-transport.md §3.4 and §4.6).
///
/// The host probe fills an [ElevationProbe]; [ElevatedExecutor.run] picks
/// the first rung of the §8.3 strategy table that the probe allows and runs
/// one argv through it, and [ElevatedExecutor.start] does the same for a
/// process the caller streams to and from (the §5.9 rank 3 relay, an
/// elevated `tail -F`). The password never enters a command line, the
/// environment or a process list: it is the first line of the channel's
/// stdin, and the prelude hands it to sudo through a builtin `printf`.
/// sudo's stderr is kept and classified into an [ElevationFailureKind],
/// never discarded, so each app renders its own copy of a rejection.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../terminal/shell_command.dart';
import 'remote_command.dart';
import 'remote_process.dart';
import 'ssh_link.dart';

/// What the host probe learned about elevation on one server
/// (03-ARCHITECTURE.md §6.1, "Elevation" row). Plain data: the probe that
/// fills it lives with the host collectors, and an engine isolate can carry
/// it.
///
/// Every flag defaults to the answer that enables nothing, so a probe that
/// could not run leaves the executor without a rung instead of a guessed
/// one.
final class ElevationProbe {
  const ElevationProbe({
    this.isRoot = false,
    this.sudoVersionLine,
    this.sudoIsRs = false,
    this.sudoNopasswd = false,
    this.doasPresent = false,
    this.doasNopasswd = false,
    this.run0Present = false,
    this.run0Nopasswd = false,
    this.printfIsBuiltin = false,
  }) : assert(
         sudoVersionLine != null || !(sudoIsRs || sudoNopasswd),
         'sudo facts need a sudo version line',
       ),
       assert(doasPresent || !doasNopasswd, 'doasNopasswd needs doasPresent'),
       assert(run0Present || !run0Nopasswd, 'run0Nopasswd needs run0Present');

  /// `id -u` printed 0: the login is root and needs no elevation (rung 1).
  final bool isRoot;

  /// The first line of `sudo -V`, or null when sudo is not installed.
  final String? sudoVersionLine;

  /// [sudoVersionLine] names sudo-rs rather than sudo. Adds the sudo-rs
  /// rejection texts to sudo's when classifying.
  final bool sudoIsRs;

  /// `sudo -n true` succeeded: a blanket NOPASSWD rule (rung 2). A rule
  /// scoped to one command fails this probe by design (§8.3, rung 2).
  final bool sudoNopasswd;

  /// `command -v doas` found doas.
  final bool doasPresent;

  /// `doas -n true` succeeded: a blanket `permit nopass` rule (rung 2).
  final bool doasNopasswd;

  /// `command -v run0` found run0.
  final bool run0Present;

  /// `run0 --no-ask-password true` succeeded: polkit lets run0 elevate
  /// without a password, the only way run0 is used (rung 6). run0 cannot
  /// read a password from a pipe.
  final bool run0Nopasswd;

  /// `command -V printf` under `sh` reported a shell builtin, so the
  /// prelude's `printf` never puts the password in a process list. The
  /// prelude rung is unavailable without it.
  final bool printfIsBuiltin;
}

/// Why elevation did not run the command. Typed, not text: each app renders
/// its own copy.
enum ElevationFailureKind {
  /// sudo rejected the password ("Sorry, try again." / "incorrect password
  /// attempt", or the sudo-rs equivalents).
  wrongPassword,

  /// The sudoers policy refuses this user or this command ("is not in the
  /// sudoers file", "may not run sudo on", "is not allowed to execute"), or
  /// doas's rules do.
  notInSudoers,

  /// sudo wants a password that nothing could give it: "a password is
  /// required" after the prelude validated and the rung-4 retry, a NOPASSWD
  /// rule the probe saw that no longer applies, or no password from the
  /// caller for a rung that needs one.
  passwordRequired,

  /// Elevation needs a terminal: sudo's `requiretty` ("you must have a
  /// tty"), or doas with a password. The PTY rung that would serve both
  /// (§8.3 rung 5) waits for spike S3.
  ttyRequired,

  /// No strategy-table rung applies to this host, or polkit denied the run0
  /// or `systemctl` rung.
  unavailable,
}

/// Elevation failed before the command ran.
final class ElevationException implements Exception {
  const ElevationException(this.kind, this.stderr);

  final ElevationFailureKind kind;

  /// What the elevation tool printed; empty when the executor refused
  /// without contacting the host.
  final String stderr;

  @override
  String toString() => stderr.isEmpty
      ? 'ElevationException(${kind.name})'
      : 'ElevationException(${kind.name}): $stderr';
}

/// Which rung [ElevatedExecutor.start] tries first.
enum ElevationAttempt {
  /// The first rung the probe allows, as [ElevatedExecutor.run] takes.
  probed,

  /// `sudo -n -- <argv>` first, also when the probe's `sudo -n true` failed:
  /// a NOPASSWD rule scoped to one command (`NOPASSWD: /usr/bin/docker`)
  /// fails that probe by design but lets this argv run (§8.3 rung 2, for
  /// the §5.9 rank 3 relay). When sudo refuses only for want of a password,
  /// the probed rung follows, so password sudo still reaches the prelude.
  /// Without sudo, or on a root login, this is [probed].
  nopasswdFirst,
}

/// Runs one argv with root privileges over an [SshLink], through the first
/// rung of the §8.3 strategy table the [ElevationProbe] allows:
///
/// 1. root login: the argv as it is;
/// 2. NOPASSWD: `sudo -n -- <argv>`, or `doas -n -- <argv>` when sudo is not
///    installed;
/// 3. password sudo or sudo-rs: the D24 prelude, password first on stdin;
/// 4. once, when the prelude validated but sudo still wants a password
///    (`timestamp_timeout=0`): `sudo -S -p '' -- <argv>`, password first;
/// 5. requiretty, or doas with a password: not until spike S3 clears a PTY
///    channel, so reported as [ElevationFailureKind.ttyRequired];
/// 6. run0, only when it works without a password;
/// 7. a `systemctl` argv under polkit: `systemctl --no-ask-password`.
///
/// Every rung runs under `env LC_ALL=C`, so sudo prints the untranslated
/// texts the classifier knows; §8.8 runs every remote command in the C
/// locale anyway. Each argv element is quoted with [quoteShellWord], so the
/// login shell, whichever it is, passes it on as one literal word.
final class ElevatedExecutor {
  ElevatedExecutor(this._link, this._probe);

  final SshLink _link;
  final ElevationProbe _probe;

  /// The prelude's own exit when `sudo -v` fails (8.3). A rejection needs
  /// this status and a classified sudo text on stderr; 125 alone may be
  /// the elevated command's own status and is then returned as such.
  static const int passwordRejectedExit = 125;

  /// Runs [argv], a program and its arguments rather than a shell string
  /// (shell constructs are `['sh', '-c', script]`), and returns its result
  /// as [SshLink.run] does, non-zero exits included.
  ///
  /// [password] is sent only on the rungs that need one (3 and 4), as the
  /// first stdin line; [stdin] follows it and reaches the command, whose
  /// stdin then ends on every rung, also when [stdin] is null. [timeout]
  /// bounds the whole call: the rung-4 retry gets what the first attempt
  /// left. Without one, each attempt takes [SshLink.run]'s default.
  ///
  /// Throws [ElevationException] when elevation refused and the command did
  /// not run, [RemoteCommandException] for transport failures and timeouts,
  /// and [ArgumentError] for an empty argv, a program name that is empty or
  /// contains `=`, a NUL byte, or a password that cannot travel as one line.
  Future<RemoteCommandResult> run(
    List<String> argv, {
    String? password,
    List<int>? stdin,
    Duration? timeout,
  }) async {
    _checkArgv(argv);
    if (password != null) _checkPassword(password);

    final strategy = selectElevationStrategy(_probe, argv);
    if (strategy != ElevationStrategy.sudoPrelude) {
      final result = await _link.run(
        buildElevatedCommand(strategy, argv),
        // Sealed even when empty, as the prelude rungs always seal it after
        // the password line: a null stdin would stay open on these rungs
        // only, and a command that reads it would wait for the timeout.
        stdin: stdin ?? const <int>[],
        timeout: timeout,
      );
      _throwIfRefused(strategy, result);
      return result;
    }

    if (password == null) {
      throw const ElevationException(ElevationFailureKind.passwordRequired, '');
    }
    final framed = [...utf8.encode('$password\n'), ...?stdin];
    final stopwatch = Stopwatch()..start();
    final first = await _link.run(
      buildElevatedCommand(ElevationStrategy.sudoPrelude, argv),
      stdin: framed,
      timeout: timeout,
    );
    if (!_wantsPasswordAfterValidation(first)) {
      _throwIfRefused(ElevationStrategy.sudoPrelude, first);
      return first;
    }

    // Rung 4: `sudo -v` accepted the password (no 125), yet `sudo -n` found
    // no cached credential, so the host caches none (`timestamp_timeout=0`).
    // sudo never started the command, so the stdin after the password line
    // is unread and goes again with the retry.
    Duration? remaining;
    if (timeout != null) {
      remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw RemoteCommandException(
          'The command did not finish within ${timeout.inSeconds}s.',
        );
      }
    }
    final retry = await _link.run(
      buildElevatedCommand(ElevationStrategy.sudoStdin, argv),
      stdin: framed,
      timeout: remaining,
    );
    _throwIfRefused(ElevationStrategy.sudoStdin, retry);
    return retry;
  }

  /// Starts [argv] as [run] would and hands back the live process, whose
  /// stdin stays open after the password line: the caller streams the
  /// command's own input and closes [RemoteProcess.stdin] when done.
  ///
  /// [ElevatedProcess.refusal] reports a refused elevation; until it
  /// completes null, stdout has carried nothing and stderr may still be
  /// the tool's. [attempt] picks the first rung: with
  /// [ElevationAttempt.nopasswdFirst], `sudo -n` goes first and the probed
  /// rung follows a refusal that only wants a password. The rung-4 retry
  /// follows the prelude as in [run]. A rung that falls back never started
  /// the command, so what the caller wrote is written again to the next
  /// one ([ElevatedProcess] says how much).
  ///
  /// Throws [ElevationException] when no rung can start without contacting
  /// the host (no rung applies, or password sudo is the only rung and
  /// [password] is null), [RemoteCommandException] or
  /// [ChannelOpenException] when the first channel does not open, and
  /// [ArgumentError] as [run] does.
  Future<ElevatedProcess> start(
    List<String> argv, {
    String? password,
    ElevationAttempt attempt = ElevationAttempt.probed,
  }) async {
    _checkArgv(argv);
    if (password != null) _checkPassword(password);

    final rungs = _startRungs(argv, password: password, attempt: attempt);
    final process = ElevatedProcess._(this, argv, password, rungs);
    await process._openRung();
    return process;
  }

  /// The rungs [start] walks for [argv], first to last; each one after the
  /// first runs only when the one before refused for want of a password.
  List<ElevationStrategy> _startRungs(
    List<String> argv, {
    required String? password,
    required ElevationAttempt attempt,
  }) {
    final sudoFirst =
        attempt == ElevationAttempt.nopasswdFirst &&
        !_probe.isRoot &&
        _probe.sudoVersionLine != null;

    final ElevationStrategy probed;
    try {
      probed = selectElevationStrategy(_probe, argv);
    } on ElevationException {
      // A scoped rule may still let `sudo -n` run this argv.
      if (sudoFirst) return const [ElevationStrategy.sudoNopasswd];
      rethrow;
    }

    final List<ElevationStrategy> probedRungs = switch (probed) {
      ElevationStrategy.sudoPrelude when password == null => const [],
      ElevationStrategy.sudoPrelude => const [
        ElevationStrategy.sudoPrelude,
        ElevationStrategy.sudoStdin,
      ],
      _ => [probed],
    };
    if (sudoFirst && probed != ElevationStrategy.sudoNopasswd) {
      return [ElevationStrategy.sudoNopasswd, ...probedRungs];
    }
    if (probedRungs.isEmpty) {
      throw const ElevationException(ElevationFailureKind.passwordRequired, '');
    }
    return probedRungs;
  }

  /// Which texts a refusal on [strategy] speaks, or null when no elevation
  /// tool runs.
  ElevationTool? _toolFor(ElevationStrategy strategy) => switch (strategy) {
    ElevationStrategy.root => null,
    ElevationStrategy.sudoNopasswd ||
    ElevationStrategy.sudoPrelude ||
    ElevationStrategy.sudoStdin =>
      _probe.sudoIsRs ? ElevationTool.sudoRs : ElevationTool.sudo,
    ElevationStrategy.doasNopasswd => ElevationTool.doas,
    ElevationStrategy.run0 ||
    ElevationStrategy.polkitSystemctl => ElevationTool.polkit,
  };

  void _throwIfRefused(ElevationStrategy strategy, RemoteCommandResult result) {
    // A tool that refused never started the command, so nothing reached
    // stdout; output there means the command ran and its status is its own.
    if (result.stdout.isNotEmpty) return;

    final refusal = _refusalOf(strategy, result.exitCode, result.stderr);
    if (refusal != null) throw refusal;
  }

  /// The refusal an attempt on [strategy] that printed nothing on stdout
  /// reports, or null when the status and [stderr] say the command ran.
  ElevationException? _refusalOf(
    ElevationStrategy strategy,
    int? exitCode,
    String stderr,
  ) {
    final tool = _toolFor(strategy);
    if (tool == null) return null;

    final refusalStatus = switch (strategy) {
      // 125 is the prelude's `sudo -v` failing; 1 is its `sudo -n` refusing.
      ElevationStrategy.sudoPrelude =>
        exitCode == passwordRejectedExit || exitCode == _toolRefusedExit,
      ElevationStrategy.run0 ||
      ElevationStrategy.polkitSystemctl => exitCode != null && exitCode != 0,
      _ => exitCode == _toolRefusedExit,
    };
    if (!refusalStatus) return null;

    final kind = classifyElevationStderr(stderr, tool);
    return kind == null ? null : ElevationException(kind, stderr);
  }

  /// Whether the prelude's own `sudo -n` refused for want of a password
  /// after `sudo -v` accepted one. Strict on purpose: the retry runs the
  /// command, so every remaining stderr line has to be that refusal.
  bool _wantsPasswordAfterValidation(RemoteCommandResult result) =>
      result.stdout.isEmpty &&
      _onlyWantsPassword(result.exitCode, result.stderr);

  /// Whether sudo, printing nothing on stdout, exited refusing for want of
  /// a password and for nothing else: the one refusal a later rung can
  /// answer.
  bool _onlyWantsPassword(int? exitCode, String stderr) {
    if (exitCode != _toolRefusedExit) return false;
    final lines = _stderrLines(
      stderr,
    ).where((line) => !_sudoNoise.hasMatch(line)).toList();
    return lines.isNotEmpty && lines.every(_isPasswordWantedLine);
  }

  /// Whether [line] is sudo asking for a password, or noise beside it.
  bool _isPasswordWantedLine(String line) =>
      _sudoNoise.hasMatch(line) ||
      _classifyLine(line, _toolFor(ElevationStrategy.sudoPrelude)!) ==
          ElevationFailureKind.passwordRequired;
}

/// A process [ElevatedExecutor.start] runs with root privileges: a
/// [RemoteProcess] whose stdin stays open after the password line, plus
/// [refusal].
///
/// Until the command starts, the rung serving it can change: a `sudo -n`
/// refusal that only wants a password moves to the probed rung
/// ([ElevationAttempt.nopasswdFirst]), and a prelude whose `sudo -n` finds
/// no cached credential moves to rung 4. The refused tool never read
/// stdin, so the bytes written to [stdin] so far go again to the next rung,
/// after its password line, and the refused rung's stderr is dropped. That
/// replay is bounded: once more than [replayLimit] bytes were written while
/// a fallback was still possible, the current rung is the last, and its
/// refusal is reported instead.
///
/// stderr reaches [stderr] as it arrives, except while the current rung
/// may still fall back: only lines asking for a password are held then,
/// so a command's own diagnostics are not delayed.
final class ElevatedProcess implements RemoteProcess {
  ElevatedProcess._(this._executor, this._argv, this._password, this._rungs) {
    _stdoutController
      ..onListen = _drainStdout
      ..onResume = _drainStdout
      ..onCancel = _cancelStdout;
    _stdinController.stream.listen(
      _writeStdin,
      onDone: _closeStdin,
      // The sink is ours; nothing upstream can fail.
      onError: (Object _) {},
    );
    // Callers may never await these; an error stays theirs to observe.
    _exitCompleter.future.ignore();
    _refusalCompleter.future.ignore();
  }

  /// Bytes of stdin kept for a replay while a fallback is still possible.
  /// The relay's first HTTP request and a `crontab -` fit many times over.
  static const replayLimit = 256 * 1024;

  /// stderr kept for classifying a refusal; sudo's texts are a few lines.
  static const _classifyLimit = 64 * 1024;

  /// stdout queued for a caller that is not reading, past which the
  /// channel pauses, as [RemoteProcess.stdout] promises.
  static const _stdoutQueueLimit = 1024 * 1024;

  final ElevatedExecutor _executor;
  final List<String> _argv;
  final String? _password;
  final List<ElevationStrategy> _rungs;

  final _stdoutController = StreamController<List<int>>();
  final _stderrController = StreamController<List<int>>();
  final _stdinController = StreamController<List<int>>();
  final _exitCompleter = Completer<RemoteExit>();
  final _refusalCompleter = Completer<ElevationException?>();

  /// Index into [_rungs] of the attempt in flight.
  var _rung = 0;

  /// The current attempt's process; null while the next one opens and
  /// after the last one ended.
  RemoteProcess? _process;
  Future<void>? _opening;

  /// Caller stdin no rung is known to have read; null once the current
  /// rung can no longer fall back.
  BytesBuilder? _replay = BytesBuilder();
  var _stdinClosed = false;
  var _closeRequested = false;

  /// The current attempt printed on stdout, so the command runs.
  var _started = false;

  /// The current attempt may still fall back to the next rung.
  var _mayFallBack = false;

  /// The current attempt's stderr while it might be a refusal.
  final _seenStderr = BytesBuilder();

  /// stderr held while the current attempt may still fall back.
  final _heldStderr = <List<int>>[];

  /// The current attempt's stdout. It is paused or cancelled for the
  /// caller only once the command started: until then every byte is
  /// awaited, since the first one decides [refusal].
  StreamSubscription<List<int>>? _stdoutSubscription;
  var _stdoutPaused = false;
  var _stdoutCancelled = false;

  /// stdout the caller has not taken yet. Queued here rather than in the
  /// controller so its size is known: pausing the channel for an idle
  /// caller would also hold back its close, and with it [exit].
  final _stdoutQueue = Queue<List<int>>();
  var _stdoutQueuedBytes = 0;
  var _stdoutEnded = false;

  /// Completes with the refusal when elevation refused before the command
  /// printed anything, with null once stdout carries a byte or the command
  /// exits without a refusal. A command that prints nothing to stdout keeps
  /// it pending until it exits. Completes with the error when a fallback
  /// rung's channel cannot open; [exit] then does too.
  Future<ElevationException?> get refusal => _refusalCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  StreamSink<List<int>> get stdin => _stdinController.sink;

  @override
  Future<RemoteExit> get exit => _exitCompleter.future;

  @override
  void signal(RemoteSignal signal) => _process?.signal(signal);

  /// Closes the current rung's process, after a fallback rung that is
  /// opening, and stops any further fallback.
  @override
  Future<void> close() async {
    _closeRequested = true;
    _settle();
    try {
      await _opening;
    } on Object {
      // Reported through [exit] and [refusal].
    }
    await _process?.close();
  }

  /// Opens [_rungs] at [_rung]: the password line first on the rungs that
  /// take one, then the replay, then live stdin.
  Future<void> _openRung() async {
    final strategy = _rungs[_rung];
    final process = await _executor._link.start(
      buildElevatedCommand(strategy, _argv),
    );
    _process = process;
    _started = false;
    _mayFallBack = _rung + 1 < _rungs.length && !_closeRequested;
    _seenStderr.clear();
    _heldStderr.clear();

    // A rung opened while the caller closes gets neither password nor input.
    final replay = _replay;
    if (!_closeRequested) {
      if (_takesPassword(strategy)) {
        process.stdin.add(utf8.encode('${_password!}\n'));
      }
      if (replay != null && replay.isNotEmpty) {
        process.stdin.add(replay.toBytes());
      }
    }
    if (!_mayFallBack) _replay = null;
    if (_stdinClosed) unawaited(_closeProcessStdin(process));

    // Settled by the first byte or the end: once the command started, a
    // full queue may pause the rest of stdout past the exit.
    final stdoutSettled = Completer<void>();
    void settleStdout() {
      if (!stdoutSettled.isCompleted) stdoutSettled.complete();
    }

    final stderrDone = Completer<void>();
    _stdoutPaused = false;
    _stdoutSubscription = process.stdout.listen(
      (data) {
        settleStdout();
        _onStdout(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        settleStdout();
        _stdoutController.addError(error, stackTrace);
      },
      onDone: () {
        settleStdout();
        if (_started) _endStdout();
      },
    );
    process.stderr.listen(
      _onStderr,
      onError: _stderrController.addError,
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
    );
    unawaited(
      _attemptEnded(strategy, process, stdoutSettled.future, stderrDone.future),
    );
  }

  bool _takesPassword(ElevationStrategy strategy) =>
      strategy == ElevationStrategy.sudoPrelude ||
      strategy == ElevationStrategy.sudoStdin;

  void _onStdout(List<int> data) {
    if (!_started) {
      _started = true;
      _settle();
      _seenStderr.clear();
      if (!_refusalCompleter.isCompleted) _refusalCompleter.complete(null);
    }
    if (_stdoutCancelled) {
      _cancelStdout().ignore();
      return;
    }
    _stdoutQueue.add(data);
    _stdoutQueuedBytes += data.length;
    _drainStdout();
    if (_stdoutQueuedBytes > _stdoutQueueLimit) _pauseStdout();
  }

  /// Hands queued stdout to a listening caller, then resumes the channel
  /// or, after the last byte, ends the stream.
  void _drainStdout() {
    while (_stdoutQueue.isNotEmpty &&
        _stdoutController.hasListener &&
        !_stdoutController.isPaused) {
      final data = _stdoutQueue.removeFirst();
      _stdoutQueuedBytes -= data.length;
      _stdoutController.add(data);
    }
    if (_stdoutQueuedBytes <= _stdoutQueueLimit) _resumeStdout();
    if (_stdoutQueue.isEmpty && _stdoutEnded && !_stdoutController.isClosed) {
      _stdoutController.close().ignore();
    }
  }

  void _endStdout() {
    _stdoutEnded = true;
    _drainStdout();
  }

  void _onStderr(List<int> data) {
    if (!_started && _seenStderr.length < _classifyLimit) {
      final room = _classifyLimit - _seenStderr.length;
      _seenStderr.add(data.length <= room ? data : data.sublist(0, room));
    }
    if (!_mayFallBack) {
      _stderrController.add(data);
      return;
    }
    _heldStderr.add(data);
    if (!_stillOnlyWantsPassword()) _settle();
  }

  /// Whether every complete stderr line so far is sudo asking for a
  /// password, so the current attempt may still fall back.
  bool _stillOnlyWantsPassword() {
    if (_seenStderr.length >= _classifyLimit) return false;
    final text = utf8.decode(_seenStderr.toBytes(), allowMalformed: true);
    final complete = text.substring(0, text.lastIndexOf('\n') + 1);
    return _stderrLines(complete).every(_executor._isPasswordWantedLine);
  }

  /// Ends the current attempt's chance to fall back: held stderr goes out
  /// and the replay is dropped.
  void _settle() {
    if (!_mayFallBack) return;
    _mayFallBack = false;
    for (final data in _heldStderr) {
      _stderrController.add(data);
    }
    _heldStderr.clear();
    if (_process != null) _replay = null;
  }

  void _writeStdin(List<int> data) {
    final replay = _replay;
    if (replay != null) {
      replay.add(data);
      if (_process != null && replay.length > replayLimit) _settle();
    }
    final process = _process;
    if (process == null) return;
    try {
      process.stdin.add(data);
    } on Object {
      // The attempt already ended; a fallback replays from [_replay].
    }
  }

  void _closeStdin() {
    _stdinClosed = true;
    final process = _process;
    if (process != null) unawaited(_closeProcessStdin(process));
  }

  Future<void> _closeProcessStdin(RemoteProcess process) async {
    try {
      await process.stdin.close();
    } on Object {
      // A channel that already closed has no stdin to end.
    }
  }

  void _pauseStdout() {
    final subscription = _stdoutSubscription;
    if (subscription == null || _stdoutPaused) return;
    _stdoutPaused = true;
    subscription.pause();
  }

  void _resumeStdout() {
    final subscription = _stdoutSubscription;
    if (subscription == null || !_stdoutPaused) return;
    _stdoutPaused = false;
    subscription.resume();
  }

  Future<void> _cancelStdout() async {
    _stdoutCancelled = true;
    if (_started) await _stdoutSubscription?.cancel();
  }

  /// Waits for the attempt on [strategy] to end, then opens the next rung
  /// or reports how the process ended.
  Future<void> _attemptEnded(
    ElevationStrategy strategy,
    RemoteProcess process,
    Future<void> stdoutSettled,
    Future<void> stderrDone,
  ) async {
    final RemoteExit ended;
    try {
      ended = await process.exit;
      await Future.wait([stdoutSettled, stderrDone]);
    } on Object catch (error, stackTrace) {
      _process = null;
      _fail(error, stackTrace);
      return;
    }
    _process = null;

    final stderr = utf8.decode(_seenStderr.toBytes(), allowMalformed: true);
    if (!_started &&
        _mayFallBack &&
        _executor._onlyWantsPassword(ended.exitCode, stderr)) {
      // The tool never started the command: its stderr was only the
      // request for a password, which the next rung answers.
      _heldStderr.clear();
      _rung++;
      final opening = _openRung();
      _opening = opening;
      try {
        await opening;
      } on Object catch (error, stackTrace) {
        _fail(error, stackTrace);
        return;
      } finally {
        _opening = null;
      }
      if (_closeRequested) await _process?.close();
      return;
    }

    _settle();
    if (!_refusalCompleter.isCompleted) {
      _refusalCompleter.complete(
        _started
            ? null
            : _executor._refusalOf(strategy, ended.exitCode, stderr),
      );
    }
    _seenStderr.clear();
    _exitCompleter.complete(ended);
    if (!_started) _endStdout();
    _stderrController.close().ignore();
  }

  void _fail(Object error, StackTrace stackTrace) {
    _settle();
    _replay = null;
    if (!_refusalCompleter.isCompleted) {
      _refusalCompleter.completeError(error, stackTrace);
    }
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.completeError(error, stackTrace);
    }
    _endStdout();
    _stderrController.close().ignore();
  }
}

/// The rungs of the §8.3 strategy table [ElevatedExecutor] can take. Rung 5
/// (a PTY with prompt detection) has no member until spike S3 clears it.
@visibleForTesting
enum ElevationStrategy {
  /// Rung 1: the login is root.
  root,

  /// Rung 2: `sudo -n -- <argv>`.
  sudoNopasswd,

  /// Rung 2 without sudo: `doas -n -- <argv>`.
  doasNopasswd,

  /// Rung 3: the D24 prelude.
  sudoPrelude,

  /// Rung 4: `sudo -S -p '' -- <argv>`, reached only as the prelude's retry.
  sudoStdin,

  /// Rung 6: `run0 --no-ask-password -- <argv>`.
  run0,

  /// Rung 7: `systemctl --no-ask-password <args>` under polkit.
  polkitSystemctl,
}

/// The D24 prelude, 03-ARCHITECTURE.md §8.3 verbatim. `read` takes exactly
/// the password line, so the rest of stdin reaches the command; both sudo
/// invocations are children of this one shell, because without a tty sudo
/// keys its cached credential to the parent PID; the trailing `exit $?`
/// stops bash from exec'ing the last command of a `-c` string, which would
/// change that parent. No `exec`, no here-document, no `2>/dev/null`.
@visibleForTesting
const elevationPrelude =
    'IFS= read -r p\n'
    "printf '%s\\n' \"\$p\" | sudo -S -p '' -v || exit 125\n"
    'p=\n'
    'sudo -n -- "\$@"\n'
    'exit \$?';

/// `$0` of the prelude shell, which names it in the shell's own messages.
const _preludeName = 'elevate';

/// Picks the first strategy-table rung [probe] allows for [argv], or throws
/// [ElevationException] when none does: [ElevationFailureKind.ttyRequired]
/// when doas with a password is all there is, otherwise
/// [ElevationFailureKind.unavailable].
@visibleForTesting
ElevationStrategy selectElevationStrategy(
  ElevationProbe probe,
  List<String> argv,
) {
  if (probe.isRoot) return ElevationStrategy.root;

  final sudoPresent = probe.sudoVersionLine != null;
  if (sudoPresent && probe.sudoNopasswd) return ElevationStrategy.sudoNopasswd;
  // Where password sudo and blanket doas NOPASSWD both exist, sudo's rungs
  // apply (§8.3 rung 2).
  if (!sudoPresent && probe.doasNopasswd) {
    return ElevationStrategy.doasNopasswd;
  }
  if (sudoPresent && probe.printfIsBuiltin) {
    return ElevationStrategy.sudoPrelude;
  }

  // Rung 5, a PTY channel for requiretty and password doas, waits for spike
  // S3; the rungs below it still apply.
  if (probe.run0Nopasswd) return ElevationStrategy.run0;
  if (_isSystemctl(argv.first)) return ElevationStrategy.polkitSystemctl;

  throw ElevationException(
    !sudoPresent && probe.doasPresent
        ? ElevationFailureKind.ttyRequired
        : ElevationFailureKind.unavailable,
    '',
  );
}

/// The command line [strategy] sends for [argv]. Fixed words are constants;
/// the prelude and every argv element go through [quoteShellWord], so no
/// value is interpolated unquoted whichever login shell parses the line.
@visibleForTesting
String buildElevatedCommand(ElevationStrategy strategy, List<String> argv) {
  final quoted = argv.map(quoteShellWord).join(' ');
  final body = switch (strategy) {
    ElevationStrategy.root => quoted,
    ElevationStrategy.sudoNopasswd => 'sudo -n -- $quoted',
    ElevationStrategy.doasNopasswd => 'doas -n -- $quoted',
    ElevationStrategy.sudoPrelude =>
      'sh -c ${quoteShellWord(elevationPrelude)} $_preludeName $quoted',
    ElevationStrategy.sudoStdin => "sudo -S -p '' -- $quoted",
    ElevationStrategy.run0 => 'run0 --no-ask-password -- $quoted',
    ElevationStrategy.polkitSystemctl => [
      quoteShellWord(argv.first),
      '--no-ask-password',
      ...argv.skip(1).map(quoteShellWord),
    ].join(' '),
  };
  return 'env LC_ALL=C $body';
}

/// Whose rejection texts a refusal speaks.
@visibleForTesting
enum ElevationTool {
  /// sudo 1.9.
  sudo,

  /// sudo-rs: its own texts plus sudo's.
  sudoRs,

  /// OpenBSD doas and OpenDoas.
  doas,

  /// polkit refusing run0 or `systemctl`.
  polkit,
}

/// Classifies the stderr of a refused elevation, line by line, or returns
/// null when no line is a known refusal. When lines disagree, the most
/// decisive kind wins: policy over tty over password.
@visibleForTesting
ElevationFailureKind? classifyElevationStderr(
  String stderr,
  ElevationTool tool,
) {
  ElevationFailureKind? found;
  for (final line in _stderrLines(stderr)) {
    final kind = _classifyLine(line, tool);
    if (kind == null) continue;
    if (found == null ||
        _precedence.indexOf(kind) < _precedence.indexOf(found)) {
      found = kind;
    }
  }
  return found;
}

/// sudo and doas exit 1 when they refuse.
const _toolRefusedExit = 1;

const _precedence = [
  ElevationFailureKind.notInSudoers,
  ElevationFailureKind.ttyRequired,
  ElevationFailureKind.wrongPassword,
  ElevationFailureKind.passwordRequired,
  ElevationFailureKind.unavailable,
];

typedef _RefusalText = (ElevationFailureKind kind, Pattern text);

/// sudo 1.9. The wrong-password and password-required lines are the ones
/// 04 Appendix A E8 recorded from sudo 1.9.15p5; the policy and tty lines
/// are sudo's catalogue spellings [R]. All are matched as substrings so
/// the `sudo: ` prefix and the trailing "This incident will be reported."
/// of older releases do not matter.
const _sudoTexts = <_RefusalText>[
  (ElevationFailureKind.wrongPassword, 'Sorry, try again.'),
  (ElevationFailureKind.wrongPassword, 'incorrect password attempt'),
  (ElevationFailureKind.wrongPassword, 'no password was provided'),
  (ElevationFailureKind.notInSudoers, 'is not in the sudoers file'),
  (ElevationFailureKind.notInSudoers, 'may not run sudo on'),
  (ElevationFailureKind.notInSudoers, 'is not allowed to execute'),
  (ElevationFailureKind.passwordRequired, 'a password is required'),
  (ElevationFailureKind.ttyRequired, 'you must have a tty'),
];

/// sudo-rs 0.2, from its sources [U: spike S3 replaces these with recorded
/// fixtures]. sudo-rs keeps some of sudo's spellings, so sudo's texts are
/// checked too.
const _sudoRsTexts = <_RefusalText>[
  (ElevationFailureKind.wrongPassword, 'Authentication failed'),
  (ElevationFailureKind.wrongPassword, 'incorrect authentication attempt'),
  (ElevationFailureKind.notInSudoers, "I'm afraid I can't do that"),
  (
    ElevationFailureKind.passwordRequired,
    'interactive authentication is required',
  ),
];

/// doas prints through `err(3)`, so its refusals are whole `doas: ` lines;
/// anchoring keeps a command's own "Operation not permitted" out [R].
final _doasTexts = <_RefusalText>[
  (
    ElevationFailureKind.passwordRequired,
    RegExp(r'^doas: (?:Authorization|Authentication) required$'),
  ),
  (
    ElevationFailureKind.notInSudoers,
    RegExp(r'^doas: Operation not permitted$'),
  ),
];

/// polkit's refusal as run0 and `systemctl` report it [R].
final _polkitTexts = <_RefusalText>[
  (
    ElevationFailureKind.unavailable,
    RegExp(
      r'^Failed to .*: (?:Interactive authentication required|Access denied)\.?$',
    ),
  ),
];

/// sudo warnings that accompany any invocation on a misconfigured host and
/// say nothing about the refusal.
final _sudoNoise = RegExp(r'^sudo: unable to resolve host ');

ElevationFailureKind? _classifyLine(String line, ElevationTool tool) {
  final texts = switch (tool) {
    ElevationTool.sudo => _sudoTexts,
    ElevationTool.sudoRs => [..._sudoRsTexts, ..._sudoTexts],
    ElevationTool.doas => _doasTexts,
    ElevationTool.polkit => _polkitTexts,
  };
  for (final (kind, text) in texts) {
    if (line.contains(text)) return kind;
  }
  return null;
}

Iterable<String> _stderrLines(String stderr) => stderr
    .split('\n')
    .map(
      (line) => line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    )
    .where((line) => line.trim().isNotEmpty);

bool _isSystemctl(String program) =>
    program == 'systemctl' || program.endsWith('/systemctl');

void _checkArgv(List<String> argv) {
  if (argv.isEmpty) {
    throw ArgumentError.value(argv, 'argv', 'Must name a program.');
  }
  final program = argv.first;
  if (program.isEmpty || program.contains('=')) {
    // `env LC_ALL=C` would read `NAME=value` as another assignment.
    throw ArgumentError.value(
      program,
      'argv',
      'The program name must be non-empty and contain no "=".',
    );
  }
  for (final word in argv) {
    if (word.contains('\u0000')) {
      throw ArgumentError.value(
        word,
        'argv',
        'An exec request cannot carry a NUL byte.',
      );
    }
  }
}

void _checkPassword(String password) {
  // The value stays out of the error: it would reach logs.
  if (password.contains(_unframeablePasswordCharacter)) {
    throw ArgumentError(
      'The password travels as one stdin line, so it cannot contain a line '
      'break or a NUL byte.',
    );
  }
}

final _unframeablePasswordCharacter = RegExp('[\n\r\u0000]');

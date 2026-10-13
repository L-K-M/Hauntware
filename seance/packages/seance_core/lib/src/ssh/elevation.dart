/// Privilege elevation over an [SshLink] (03-ARCHITECTURE.md §8.3, D24;
/// seance-core-transport.md §3.4 and §4.6).
///
/// The host probe fills an [ElevationProbe]; [ElevatedExecutor.run] picks
/// the first rung of the §8.3 strategy table that the probe allows and runs
/// one argv through it. The password never enters a command line, the
/// environment or a process list: it is the first line of the channel's
/// stdin, and the prelude hands it to sudo through a builtin `printf`.
/// sudo's stderr is kept and classified into an [ElevationFailureKind],
/// never discarded, so each app renders its own copy of a rejection.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../terminal/shell_command.dart';
import 'remote_command.dart';
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
    final tool = _toolFor(strategy);
    if (tool == null) return;

    // A tool that refused never started the command, so nothing reached
    // stdout; output there means the command ran and its status is its own.
    if (result.stdout.isNotEmpty) return;

    final exitCode = result.exitCode;
    final refusalStatus = switch (strategy) {
      // 125 is the prelude's `sudo -v` failing; 1 is its `sudo -n` refusing.
      ElevationStrategy.sudoPrelude =>
        exitCode == passwordRejectedExit || exitCode == _toolRefusedExit,
      ElevationStrategy.run0 ||
      ElevationStrategy.polkitSystemctl => exitCode != null && exitCode != 0,
      _ => exitCode == _toolRefusedExit,
    };
    if (!refusalStatus) return;

    final kind = classifyElevationStderr(result.stderr, tool);
    if (kind != null) throw ElevationException(kind, result.stderr);
  }

  /// Whether the prelude's own `sudo -n` refused for want of a password
  /// after `sudo -v` accepted one. Strict on purpose: the retry runs the
  /// command, so every remaining stderr line has to be that refusal.
  bool _wantsPasswordAfterValidation(RemoteCommandResult result) {
    if (result.exitCode != _toolRefusedExit || result.stdout.isNotEmpty) {
      return false;
    }
    final tool = _toolFor(ElevationStrategy.sudoPrelude)!;
    final lines = _stderrLines(
      result.stderr,
    ).where((line) => !_sudoNoise.hasMatch(line)).toList();
    return lines.isNotEmpty &&
        lines.every(
          (line) =>
              _classifyLine(line, tool) ==
              ElevationFailureKind.passwordRequired,
        );
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

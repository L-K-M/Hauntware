import '../terminal/shell_command.dart';
import 'remote_command.dart';

/// Reads the interactive shell's working directory from beside it, for
/// shells that never report one.
///
/// Séance follows a shell through OSC 7 or a cwd-shaped title, but some
/// shells emit neither: TrueNAS's zsh sets a prompt and nothing else. On a
/// Linux server the directory is still visible in `/proc`, and sshd forks
/// every channel of one connection from that connection's own process, so
/// a probe on an exec channel finds its sibling PTY shell:
///
/// ```text
/// sshd (one process per connection, i.e. per Séance tab)
///  ├─ -zsh            PTY shell: a session leader with a terminal
///  ├─ sftp-server     SFTP subsystem: no terminal
///  └─ sh -c <probe>   this probe: no terminal
/// ```
///
/// The probe never touches the interactive shell. It reads the login
/// shell's directory, so a nested shell (`sudo -i`, `bash` inside zsh,
/// tmux) is not followed; OSC 7 from that shell covers those.
class RemoteShellDirectory {
  final RemoteCommandRunner _run;

  /// Set once the server cannot answer at all (no `/proc`, a login shell
  /// that cannot run `sh`, a forced command), or kept failing, so later
  /// reads cost no channel.
  bool _gaveUp = false;

  /// Reads in a row that failed without saying why: a timeout, a refused
  /// or dropped channel, a killed probe, a fork that failed under load.
  int _failures = 0;

  RemoteShellDirectory(this._run);

  static const Duration _timeout = Duration(seconds: 3);

  /// A hung read can hold one of the server's per-connection sessions until
  /// it ends, so a server that keeps failing is not asked again.
  static const int _maxFailures = 3;

  /// The script's "no answer this time" status (`exit 4`): no single PTY
  /// shell on the connection yet, or its directory cannot be read.
  static const int _noAnswerExitCode = 4;

  /// The server cannot run the script: the script's own `exit 3` (no Linux
  /// `/proc` or `readlink`), and the shell's 126 and 127 (no runnable `sh`).
  static const Set<int> _cannotAnswerExitCodes = {3, 126, 127};

  /// What the kernel appends to the directory of a shell whose directory
  /// was removed.
  static const String _deletedSuffix = ' (deleted)';

  /// The line the script prints before its answer. bash sources `~/.bashrc`
  /// for commands sshd runs, and anything a startup file prints comes first,
  /// so the answer is what follows this line.
  static const String _answerMarker = 'seance-cwd';

  /// One line of POSIX sh: csh and tcsh reject a newline inside quotes, and
  /// the script has no `'`, `\` or `!`, so [quoteShellWord] keeps it literal
  /// through every login shell.
  ///
  /// `st` reads a process's command name, ppid, session and tty from
  /// `/proc/<pid>/stat`. The name may contain `) ` or a newline, so fields
  /// are taken after the last `) ` and a line too short to be a whole stat
  /// line is refused rather than read as forged fields. The connection is
  /// the probe's parent: Dropbear does not start exec channels in sessions
  /// of their own. Its `children` file is read when the kernel has one; a
  /// scan of `/proc` is the fallback. A candidate still named like the
  /// connection has not become the shell yet: sshd gives it the terminal
  /// before it changes directory and starts the shell. `readlink` names the
  /// directory without touching its file system, which may hang. The answer
  /// follows [_answerMarker].
  static const String _script =
      r'[ -r /proc/self/stat ] && command -v readlink >/dev/null || exit 3; '
      r'st() { IFS= read -r s < "/proc/$1/stat" || return 1; '
      r'c=${s#*(}; c=${c%) *}; s=${s##*) }; set -- $s; '
      r'[ $# -gt 20 ] || return 1; ppid=$2; sid=$4; tty=$5; }; '
      r'st $$ || exit 4; conn=$ppid; cc=; st "$conn" 2>/dev/null && cc=$c; '
      r'kids=; [ -r "/proc/$conn/task/$conn/children" ] && '
      r'read -r kids < "/proc/$conn/task/$conn/children"; '
      r'if [ -z "$kids" ]; then '
      r'for d in /proc/[0-9]*; do kids="$kids ${d#/proc/}"; done; fi; '
      r'shell=; for p in $kids; do st "$p" 2>/dev/null || continue; '
      r'[ "$ppid" = "$conn" ] && [ "$sid" = "$p" ] || continue; '
      r'[ "$tty" = 0 ] && continue; [ -z "$shell" ] || exit 4; '
      r'shell=$p; sc=$c; done; [ -n "$shell" ] || exit 4; '
      r'[ "$sc" = "$cc" ] && exit 4; '
      'echo $_answerMarker; '
      r'readlink "/proc/$shell/cwd" 2>/dev/null || exit 4';

  /// False once the server cannot answer: reads then return null without
  /// asking, and a caller should stop relying on earlier answers.
  bool get available => !_gaveUp;

  /// The PTY shell's absolute directory, or null when there is no answer
  /// this time or the server cannot give one ([available]). Never throws:
  /// following is a convenience, and a failing session reports itself
  /// elsewhere.
  Future<String?> read() async {
    if (_gaveUp) return null;
    final RemoteCommandResult result;
    try {
      result = await _run(
        'exec sh -c ${quoteShellWord(_script)}',
        timeout: _timeout,
      );
    } on Exception {
      // The transport failed: a [RemoteCommandException], or a budgeted
      // runner refusing the channel.
      _fail();
      return null;
    }
    final exitCode = result.exitCode;
    if (exitCode == _noAnswerExitCode) {
      _failures = 0;
      return null;
    }
    if (_cannotAnswerExitCodes.contains(exitCode)) {
      _gaveUp = true;
      return null;
    }
    if (exitCode != 0) {
      _fail();
      return null;
    }
    // Without the marker the script never ran: a forced command or a login
    // shell that is not one, which will not change.
    final answer = _answerIn(result.stdout);
    if (answer == null) {
      _gaveUp = true;
      return null;
    }
    _failures = 0;
    return _followable(answer);
  }

  /// The line after the first [_answerMarker] line, without its newline.
  static String? _answerIn(String output) {
    const markerLine = '$_answerMarker\n';
    final int start;
    if (output.startsWith(markerLine)) {
      start = markerLine.length;
    } else {
      final at = output.indexOf('\n$markerLine');
      if (at < 0) return null;
      start = at + 1 + markerLine.length;
    }
    final answer = output.substring(start);
    return answer.endsWith('\n')
        ? answer.substring(0, answer.length - 1)
        : answer;
  }

  void _fail() {
    if (++_failures >= _maxFailures) _gaveUp = true;
  }

  /// A removed directory, or one whose name holds a control character or
  /// bytes that are not UTF-8 (decoded as U+FFFD, which SFTP could not
  /// open), is not followed. A newline would also mean the output is not
  /// one path.
  static String? _followable(String path) {
    if (!path.startsWith('/') || path.endsWith(_deletedSuffix)) return null;
    final unfollowable = path.runes.any(
      (codePoint) =>
          codePoint <= 0x1f ||
          (codePoint >= 0x7f && codePoint <= 0x9f) ||
          codePoint == 0xfffd,
    );
    return unfollowable ? null : path;
  }
}

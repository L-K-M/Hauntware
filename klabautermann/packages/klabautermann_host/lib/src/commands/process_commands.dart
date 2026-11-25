part of 'commands.dart';

/// The signals a guarded kill may send (PRC-02, 03 §7.2, §8.8 "signal
/// names (enum)"): the ones a person picks for a process. Each [wireName]
/// passes [ArgValidators.signalName].
enum KillSignal {
  sighup('HUP'),
  sigint('INT'),
  sigquit('QUIT'),
  sigabrt('ABRT'),
  sigkill('KILL'),
  sigusr1('USR1'),
  sigusr2('USR2'),
  sigalrm('ALRM'),
  sigterm('TERM'),
  sigcont('CONT'),
  sigstop('STOP'),
  sigtstp('TSTP'),
  sigwinch('WINCH');

  const KillSignal(this.wireName);

  /// The name `kill -s` takes, without the `SIG` prefix.
  final String wireName;
}

/// [HostCommands.processDetail]'s exit when the PID's start ticks are not
/// the ones asked for: it names another process now.
const int kProcessDetailReused = 4;

/// The line that opens each section of [HostCommands.processDetail]'s
/// output, before the section's name.
const String kProcessDetailMarker = '==';

/// A section of [HostCommands.processDetail] the login user may not read.
const String kProcessDetailDenied = '== denied';

/// The most environment entries [HostCommands.processDetail] prints.
const int kProcessEnvironLimit = 500;

/// [HostCommands.guardedKill]'s exit when the signal was sent.
const int kGuardedKillSignalled = 0;

/// [HostCommands.guardedKill]'s exit when `/proc/<pid>` is gone: the
/// process has exited.
const int kGuardedKillGone = kStartTicksGone;

/// [HostCommands.guardedKill]'s exit when the start ticks differ: the PID
/// now names another process, which was not signalled.
const int kGuardedKillReused = 4;

/// [HostCommands.guardedKill]'s exit when `/proc/<pid>/stat` could not be
/// read or split; nothing was signalled.
const int kGuardedKillUnreadable = kStartTicksUnreadable;

/// [HostCommands.guardedKill]'s exit when the start ticks matched but
/// `kill` failed; its stderr says why (`Operation not permitted` asks for
/// elevation, `No such process` means the process exited in between).
const int kGuardedKillFailed = 6;

/// [HostCommands.guardedKill]'s exit when the script refused its own
/// positional parameters (a second check behind the builder's).
const int kGuardedKillInvalid = 7;

/// What a guarded kill's exit status means (03 §7.2). The codes avoid 1
/// and 2, which sudo, `sh` and `kill` use for their own failures, and
/// 126 and 127, which mean the script never ran.
enum GuardedKillOutcome {
  signalled(kGuardedKillSignalled),
  gone(kGuardedKillGone),
  reused(kGuardedKillReused),
  unreadable(kGuardedKillUnreadable),
  killFailed(kGuardedKillFailed),
  invalid(kGuardedKillInvalid);

  const GuardedKillOutcome(this.exitCode);

  /// The script's exit status for this outcome.
  final int exitCode;

  /// The outcome [exitCode] names, or null for any other status (the
  /// elevation or the login shell failed before the script decided).
  static GuardedKillOutcome? fromExitCode(int exitCode) {
    for (final o in values) {
      if (o.exitCode == exitCode) return o;
    }
    return null;
  }
}

/// The guarded kill script (03 §7.2): checks its parameters, re-reads the
/// start ticks, and signals only on a match. The window between the read
/// and `kill` is the shell's own; PID reuse inside it needs the PID space
/// to wrap within that instant. The signal check spells its letters out:
/// a range such as `[A-Z]` follows the locale's collation.
const String _kGuardedKillScript =
    '''
$kStartTicksFunction
case \$1 in '' | 0* | *[!0-9]*) exit $kGuardedKillInvalid ;; esac
case \$2 in '' | *[!0-9]*) exit $kGuardedKillInvalid ;; esac
case \$3 in '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*) exit $kGuardedKillInvalid ;; esac
klab_ticks "\$1" || exit \$?
[ "\$KT" = "\$2" ] || exit $kGuardedKillReused
kill -s "\$3" "\$1" || exit $kGuardedKillFailed''';

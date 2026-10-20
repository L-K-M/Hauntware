/// Command builders for the interactive views (03 §8.8). Every builder
/// validates its arguments with [ArgValidators] and returns an argv list;
/// [HostCommands.commandLine] turns one into the remote command line with
/// the caller's injected `quoteShellWord`, the only quoting there is.
library;

import '../cron/document.dart' show splitCronCommand;
import '../hws/collector.dart' show ArgValidators;
import '../hws/request.dart' show ShellQuote;
import 'proc_stat.dart';

/// The first systemd major whose `systemd-analyze calendar` takes
/// `--iterations`; older ones print one elapse per expression (03 §7.7).
const int kCalendarIterationsSystemd = 242;

/// A command refused before building: an argument failed its validator
/// (03 §8.8).
final class HostCommandError implements Exception {
  const HostCommandError(this.reason, {this.argument});

  /// Why the argument was refused.
  final String reason;

  /// The offending argument, when relevant.
  final String? argument;

  @override
  String toString() {
    final a = argument == null ? '' : ' (argument: $argument)';
    return 'HostCommandError: $reason$a';
  }
}

/// The `systemctl` verbs the unit view may run (03 §7.5).
enum SystemctlVerb {
  show,
  status,
  start,
  stop,
  restart,
  reload,
  enable,
  disable,
}

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

/// The crontab spools JOB-03 lists, in the order tried (03 §7.7, M14):
/// Debian, Ubuntu and BusyBox crond keep `crontabs/` under
/// `/var/spool/cron`, which on Debian holds other spools too; cronie
/// (RHEL, Fedora) keeps the files in `/var/spool/cron` itself.
const List<String> kCrontabSpools = [
  '/var/spool/cron/crontabs',
  '/var/spool/cron',
];

/// [HostCommands.crontabSpoolList]'s exit when it listed a spool (the
/// list may be empty).
const int kCrontabSpoolListed = 0;

/// [HostCommands.crontabSpoolList]'s exit when no spool directory exists.
const int kCrontabSpoolMissing = 3;

/// [HostCommands.crontabSpoolList]'s exit when the first spool that exists
/// cannot be listed: Debian's is `1730 root:crontab`, so the listing needs
/// elevation. An unreadable directory never reads as an empty one.
const int kCrontabSpoolDenied = 4;

/// The spool listing (03 §7.7, M14): the first directory among its
/// positional parameters that exists, on the first line, then the name
/// of each regular file in it that is not a symlink, one per line. The
/// glob skips dot files; the reader validates each name as a user name.
const String _kCrontabSpoolScript =
    '''
for d do
  [ -d "\$d" ] || continue
  [ -r "\$d" ] && [ -x "\$d" ] || exit $kCrontabSpoolDenied
  printf '%s\\n' "\$d"
  for f in "\$d"/*; do
    [ -f "\$f" ] && [ ! -h "\$f" ] || continue
    printf '%s\\n' "\${f##*/}"
  done
  exit $kCrontabSpoolListed
done
exit $kCrontabSpoolMissing''';

/// The order `journalctl` reads in (03 §7.6, §10.1). journalctl refuses
/// `--reverse` together with `--follow`, so the two are one choice.
enum JournalOrder {
  /// Oldest first, journalctl's default.
  oldestFirst,

  /// Newest first (`-r`): a window, and its older pages after a cursor.
  newestFirst,

  /// Follow (`-f`): the earlier records oldest first, then each new one.
  follow,
}

/// [HostCommands.anacron]'s exit when it printed the table and stamps.
const int kAnacronListed = 0;

/// [HostCommands.anacron]'s exit when `/etc/anacrontab` does not exist:
/// anacron is not installed.
const int kAnacronMissing = 3;

/// [HostCommands.anacron]'s exit when `/etc/anacrontab` exists but could
/// not be read.
const int kAnacronUnreadable = 4;

/// The marker before anacron's job stamps in [HostCommands.anacron]'s
/// output; the table comes before it.
const String kAnacronStampsMarker = '== klabautermann anacron stamps ==';

/// Prints `/etc/anacrontab`, then [kAnacronStampsMarker], then one
/// `<job> <stamp>` line per file under `/var/spool/anacron` (JOB-04, 03
/// §7.7); an unreadable stamp prints `?`.
const String _kAnacronScript =
    '''
[ -e /etc/anacrontab ] || exit $kAnacronMissing
cat /etc/anacrontab || exit $kAnacronUnreadable
printf '\n%s\n' '$kAnacronStampsMarker'
for f in /var/spool/anacron/*; do
  [ -f "\$f" ] || continue
  d=\$(cat -- "\$f" 2>/dev/null) || d='?'
  printf '%s %s\n' "\${f##*/}" "\${d:-?}"
done
exit $kAnacronListed''';

/// The syslog identifiers cron daemons log their runs under (JOB-05, 03
/// §7.7): Debian's and Ubuntu's cron, cronie and BusyBox crond.
const List<String> kCronJournalIdentifiers = ['CRON', 'CROND', 'crond'];

/// How a cron command runs as another user (JOB-19, 03 §7.7): util-linux
/// `runuser`, which root runs without a password prompt or PAM session
/// checks, or `su` where a host lacks it (BusyBox).
enum RunAsTool { runuser, su }

/// The locale [HostCommands.commandLine] exports (03 §8.8, A11Y-08).
enum CommandLocale {
  /// `C`: for output only the engine reads, and on hosts without
  /// `C.UTF-8`.
  c('C'),

  /// `C.UTF-8`: for text people read, on a host whose probe found the
  /// locale (03 §6.1, D49); plain `C` escapes or replaces non-ASCII text
  /// in some tools.
  cUtf8('C.UTF-8');

  const CommandLocale(this.value);

  /// The `LC_ALL` value.
  final String value;
}

/// Validated command builders (03 §8.8).
abstract final class HostCommands {
  /// The command line that runs [argv] on the host (03 §8.8): `sh -c`
  /// exports the sampler's environment (6.2) with [locale] and then
  /// `exec`s [argv], which follows the script as its positional
  /// parameters. The script is a constant, so each word is quoted once,
  /// by [quote], for the login shell alone, and `sh` receives the words
  /// as given whenever [quote] suits that shell (`quoteShellWord`: sh,
  /// bash, zsh and fish). The clock and calendar reads that need the
  /// server zone unset `TZ` in their own subshell ([onCalendar]).
  static String commandLine(
    List<String> argv, {
    required ShellQuote quote,
    CommandLocale locale = CommandLocale.c,
  }) {
    if (argv.isEmpty) throw const HostCommandError('empty command');
    return [
      'sh',
      '-c',
      'export LC_ALL=${locale.value} TZ=UTC SYSTEMD_PAGER= NO_COLOR=1; '
          'exec "\$@"',
      'sh',
      ...argv,
    ].map(quote).join(' ');
  }

  /// `systemctl --no-ask-password <verb> -- <unit>` (03 §7.5).
  /// `--no-ask-password` fails fast where a polkit prompt would block.
  static List<String> systemctl(SystemctlVerb verb, String unit) {
    _check(ArgValidators.unitName, unit);
    return ['systemctl', '--no-ask-password', verb.name, '--', unit];
  }

  /// `systemctl --no-ask-password start -- <unit>` for "run timer now"
  /// (JOB-08, 03 §7.7, M13): starts the unit the timer activates, with
  /// SVC-03's guards. [activates] is the timer's `Unit=`, any unit but a
  /// timer [R: systemd.timer(5)]; the caller follows its journal with
  /// [journalctl]'s `unit`, `since` and [JournalOrder.follow].
  static List<String> timerStart(String activates) {
    _check(ArgValidators.unitName, activates);
    if (activates.endsWith('.timer')) {
      throw HostCommandError('a timer activates no timer', argument: activates);
    }
    return systemctl(SystemctlVerb.start, activates);
  }

  /// The guarded kill (PRC-02, 03 §7.2): `sh -c` with a constant script
  /// that re-reads field 22 of `/proc/<pid>/stat` and runs
  /// `kill -s <signal> <pid>` only when it equals [startTicks], the value
  /// the plan recorded from the `procs` row. The PID, ticks and signal
  /// follow the script as positional parameters. The exit status is one
  /// of [GuardedKillOutcome]'s; [kGuardedKillReused] means the PID now
  /// names another process. Elevation, for other users' processes, wraps
  /// the whole argv.
  static List<String> guardedKill(int pid, int startTicks, KillSignal signal) {
    if (pid <= 0) {
      throw HostCommandError('pid must be positive', argument: '$pid');
    }
    if (startTicks < 0) {
      throw HostCommandError('negative start ticks', argument: '$startTicks');
    }
    return [
      'sh',
      '-c',
      _kGuardedKillScript,
      'klabautermann-kill',
      '$pid',
      '$startTicks',
      signal.wireName,
    ];
  }

  /// Prints process [pid]'s start time in clock ticks, field 22 of
  /// `/proc/<pid>/stat`, for an operation's re-validation (03 §8.5). It
  /// exits 3 when the process is gone and 5 when its stat is unreadable,
  /// as the guarded kill's reader does.
  static List<String> startTicks(int pid) {
    if (pid <= 0) {
      throw HostCommandError('pid must be positive', argument: '$pid');
    }
    return [
      'sh',
      '-c',
      '${kStartTicksFunction}klab_ticks "\$1" || exit \$?\n'
          "printf '%s\\n' \"\$KT\"",
      'klabautermann-ticks',
      '$pid',
    ];
  }

  /// Prints the owner of process [pid]'s `/proc` entry and its `comm`,
  /// `<uid> <comm>`, for planning a kill (03 §7.2): the uid decides
  /// whether it needs elevation, the comm whether it is protected. The
  /// owner is the effective uid, and root for a non-dumpable process, so
  /// such a kill elevates even when it is the user's own: safe, if more
  /// than needed. It exits 3 when the process is gone.
  static List<String> processFacts(int pid) {
    if (pid <= 0) {
      throw HostCommandError('pid must be positive', argument: '$pid');
    }
    return [
      'sh',
      '-c',
      'u=\$(stat -c %u "/proc/\$1" 2>/dev/null) || exit 3\n'
          'IFS= read -r c 2>/dev/null <"/proc/\$1/comm" || exit 3\n'
          "printf '%s %s\\n' \"\$u\" \"\$c\"",
      'klabautermann-facts',
      '$pid',
    ];
  }

  /// Prints the unit timer [timer] activates (its `Unit=`), for JOB-08's
  /// run-timer-now plan (03 §7.7).
  static List<String> timerActivates(String timer) {
    _check(ArgValidators.unitName, timer);
    return ['systemctl', 'show', '--property=Unit', '--value', '--', timer];
  }

  /// Prints systemd's load state of [unit] (`loaded`, `not-found`, ...),
  /// for an operation's re-validation (03 §8.5): a unit that no longer
  /// loads is not acted on.
  static List<String> unitLoadState(String unit) {
    _check(ArgValidators.unitName, unit);
    return ['systemctl', 'show', '--property=LoadState', '--value', '--', unit];
  }

  /// The crontab spool listing for JOB-03 (03 §7.7, M14), run elevated:
  /// the first of [kCrontabSpools] that exists, then its file names, read
  /// by `parseCrontabSpool`. The exit is [kCrontabSpoolListed],
  /// [kCrontabSpoolMissing] or [kCrontabSpoolDenied]. Each name then goes
  /// to [crontabList] after the user-name check. The spools are
  /// positional parameters, so [spools] can point a test elsewhere.
  static List<String> crontabSpoolList({List<String> spools = kCrontabSpools}) {
    if (spools.isEmpty) throw const HostCommandError('no spool directory');
    for (final d in spools) {
      _check(ArgValidators.absolutePath, d);
    }
    return ['sh', '-c', _kCrontabSpoolScript, 'klabautermann-spool', ...spools];
  }

  /// `journalctl -o json` with the log view's filters (03 §7.6, §10.1):
  /// the kernel log (`-k -b`), unit, identifier, the current boot,
  /// priority floor, time range, resume cursor, window size ([lines]),
  /// [order] and a grep pattern. Every supplied filter is validated.
  /// Refused here are what journalctl refuses, `--since` with a cursor
  /// (it takes one starting point) and a range that ends before it
  /// starts, and, as this builder's choice, a follow with `--until`,
  /// since a follow reads on to the present. A follow after a cursor
  /// prints every record after it (`--no-tail`), so it takes no [lines]:
  /// up to systemd 253, the 10 lines `-f` implies end its first pass and
  /// hold the rest back until the journal next changes. The kernel log
  /// takes unit and identifier filters: journald names its records
  /// (`kernel`, or the `name[pid]:` prefix of a line written to
  /// `/dev/kmsg`) and gives the lines it wrote there itself its own unit.
  static List<String> journalctl({
    bool kernel = false,
    String? unit,
    String? identifier,
    bool currentBoot = false,
    String? priority,
    DateTime? since,
    DateTime? until,
    String? cursor,
    int? lines,
    JournalOrder order = JournalOrder.oldestFirst,
    String? grep,
  }) {
    if (unit != null) _check(ArgValidators.unitName, unit);
    if (identifier != null) {
      _check(ArgValidators.syslogIdentifier, identifier);
    }
    if (priority != null) _check(ArgValidators.journalPriority, priority);
    if (cursor != null) _check(ArgValidators.journalCursor, cursor);
    if (grep != null) _check(ArgValidators.journalGrep, grep);
    if (lines != null && lines < 0) {
      throw const HostCommandError('negative line count');
    }
    if (since != null && cursor != null) {
      throw const HostCommandError('--since and a cursor exclude each other');
    }
    if (until != null && order == JournalOrder.follow) {
      throw const HostCommandError('a follow reads up to the present');
    }
    final resume = cursor != null && order == JournalOrder.follow;
    if (resume && lines != null) {
      throw const HostCommandError('a resumed follow prints all after it');
    }
    if (since != null && until != null && since.isAfter(until)) {
      throw const HostCommandError('--since is after --until');
    }
    return [
      'journalctl',
      '-o',
      'json',
      '--no-pager',
      if (kernel) '-k',
      if (kernel || currentBoot) '-b',
      if (unit != null) ...['-u', unit],
      if (identifier != null) ...['-t', identifier],
      if (priority != null) ...['-p', priority],
      if (since != null) '--since=${_journalTime(since)}',
      if (until != null) '--until=${_journalTime(until)}',
      if (cursor != null) '--after-cursor=$cursor',
      if (resume) '--no-tail',
      if (lines != null) ...['-n', '$lines'],
      ...switch (order) {
        JournalOrder.oldestFirst => const <String>[],
        JournalOrder.newestFirst => const ['-r'],
        JournalOrder.follow => const ['-f'],
      },
      if (grep != null) ...['-g', grep],
    ];
  }

  /// `dmesg --json --decode`, the kernel log's fallback (LOG-03, 03
  /// §7.6), read by `parseDmesgJson`. `--decode` names each record's
  /// facility and level: the one number util-linux prints without it
  /// changed layout in 2.40. It prints the whole ring buffer: dmesg takes
  /// no record count, so the reader keeps the newest itself.
  static List<String> dmesgJson() => const ['dmesg', '--json', '--decode'];

  /// `tail -n <lines> [-F] -- <path>` for one file (LOG-22, 03 §7.6): its
  /// last [lines] lines, then with [follow] each appended line, following
  /// the name across rotation (`-F` retries a missing or replaced file).
  /// The path must be absolute and normalized (03 §8.8).
  static List<String> tail(
    String path, {
    required int lines,
    bool follow = false,
  }) {
    _check(ArgValidators.absolutePath, path);
    if (lines < 0) throw const HostCommandError('negative line count');
    return ['tail', '-n', '$lines', if (follow) '-F', '--', path];
  }

  /// anacron's table and job stamps (JOB-04, 03 §7.7); the exit codes are
  /// [kAnacronListed], [kAnacronMissing] and [kAnacronUnreadable], and
  /// `parseAnacron` reads the output.
  static List<String> anacron() => const [
    'sh',
    '-c',
    _kAnacronScript,
    'klabautermann-anacron',
  ];

  /// A timer's last run (JOB-05, 03 §7.7): `systemctl show` of the
  /// timer's `LastTriggerUSec` and the result of [service], the unit it
  /// activates; `parseTimerLastRun` reads the two blocks.
  static List<String> timerLastRun(String timer, String service) {
    _check(ArgValidators.timerUnit, timer);
    _check(ArgValidators.unitName, service);
    return [
      'systemctl',
      'show',
      '--property=Id,LastTriggerUSec,Result,ExecMainStatus,'
          'ExecMainExitTimestamp',
      '--',
      timer,
      service,
    ];
  }

  /// cron's own log of the jobs it started (JOB-05, 03 §7.7): the newest
  /// [lines] records under [kCronJournalIdentifiers], newest first.
  /// `parseCronRuns` reads them; cron records no exit status.
  static List<String> cronRuns({required int lines}) {
    if (lines < 0) throw const HostCommandError('negative line count');
    return [
      'journalctl',
      '-o',
      'json',
      '--no-pager',
      for (final id in kCronJournalIdentifiers) ...['-t', id],
      '-n',
      '$lines',
      '-r',
    ];
  }

  /// A cron job's command run now (JOB-19, 03 §7.7): `sh -c` with the
  /// command [splitCronCommand] split off, as the login user or, through
  /// elevation, as [asUser] with [tool]. The caller feeds the split's
  /// standard input and runs a long job detached (7.17).
  static List<String> runCronCommand(
    String command, {
    String? asUser,
    RunAsTool tool = RunAsTool.runuser,
  }) {
    if (command.trim().isEmpty || command.codeUnits.contains(0)) {
      throw HostCommandError('not a command', argument: command);
    }
    if (asUser == null) return ['sh', '-c', command];
    _check(ArgValidators.userName, asUser);
    return switch (tool) {
      RunAsTool.runuser => ['runuser', '-u', asUser, '--', 'sh', '-c', command],
      RunAsTool.su => ['su', '-s', '/bin/sh', '-c', command, asUser],
    };
  }

  /// `crontab -l -u <user>` for the jobs view's user switch (03 §7.7).
  static List<String> crontabList(String user) {
    _check(ArgValidators.userName, user);
    return ['crontab', '-l', '-u', user];
  }

  /// `df -PT -B1 [<path>]` for one mount's numbers, or `df -Pi` for inode
  /// pressure (03 §7.3). The path is validated but `df` flags are fixed.
  static List<String> df({String? path, bool inodes = false}) {
    if (path != null) _check(ArgValidators.absolutePath, path);
    return [
      'df',
      if (inodes) '-Pi' else ...['-PT', '-B1'],
      if (path != null) path,
    ];
  }

  /// `ss -tulpn` for the listening-ports list (03 §7.4).
  static List<String> ss() => const ['ss', '-tulpn'];

  /// `(unset TZ; systemd-analyze calendar --iterations=N -- '<expr>')`
  /// for the OnCalendar preview (03 §7.7): the subshell clears a session
  /// TZ so the expression resolves in the server zone, and `--` keeps an
  /// expression that starts with `-` an operand. Below systemd 242
  /// `--iterations` does not exist and is left off ([systemdMajor] null
  /// keeps it: unknown versions get the modern flag).
  static List<String> onCalendar(
    String expression, {
    required int iterations,
    int? systemdMajor,
  }) {
    _check(ArgValidators.calendarExpression, expression);
    if (iterations <= 0) {
      throw const HostCommandError('iterations must be positive');
    }
    final it = systemdMajor != null && systemdMajor < kCalendarIterationsSystemd
        ? ''
        : ' --iterations=$iterations';
    return [
      'sh',
      '-c',
      '(unset TZ; systemd-analyze calendar$it -- "\$1")',
      'hws-cal',
      expression,
    ];
  }

  /// An instant as journalctl's `@<seconds since the epoch>` timestamp
  /// (systemd.time(7)), with the microseconds when there are any, so the
  /// session's zone plays no part.
  static String _journalTime(DateTime t) {
    final us = t.microsecondsSinceEpoch;
    if (us < 0) throw HostCommandError('time before the epoch', argument: '$t');
    final fraction = us % 1000000;
    final seconds = '@${us ~/ 1000000}';
    if (fraction == 0) return seconds;
    return '$seconds.${'$fraction'.padLeft(6, '0')}';
  }

  static void _check(String? Function(String) validator, String value) {
    final reason = validator(value);
    if (reason != null) {
      throw HostCommandError(reason, argument: value);
    }
  }
}

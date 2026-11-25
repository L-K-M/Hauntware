/// Command builders for the interactive views (03 §8.8). Every builder
/// validates its arguments with [ArgValidators] and returns an argv list;
/// [HostCommands.commandLine] turns one into the remote command line with
/// the caller's injected `quoteShellWord`, the only quoting there is.
library;

import '../cron/document.dart' show splitCronCommand;
import '../hws/collector.dart' show ArgValidators;
import '../hws/request.dart' show ShellQuote;
import '../parse/packages.dart' show PackageManager;
import '../parse/accounts.dart' show kAccountsGroupMarker, kAccountsWhoMarker;
import '../parse/registry_heads.dart';
import 'proc_stat.dart';

part 'audit_commands.dart';
part 'cron_commands.dart';
part 'disk_commands.dart';
part 'firewall_commands.dart';
part 'journal_commands.dart';
part 'logs_commands.dart';
part 'network_commands.dart';
part 'process_commands.dart';
part 'security_commands.dart';
part 'system_commands.dart';
part 'units_commands.dart';

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

  /// `systemctl --no-ask-password <verb> -- <unit>` (03 §7.5), for
  /// [manager]'s units. `--no-ask-password` fails fast where a polkit
  /// prompt would block.
  static List<String> systemctl(
    SystemctlVerb verb,
    String unit, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, unit);
    return [...manager._head, '--no-ask-password', verb.wireName, '--', unit];
  }

  /// `systemctl show` of one timer's triggers and randomized delay
  /// (JOB-02, 03 §7.7, D57): the same read as the sampler's on-demand
  /// `timer_detail` collector, run on a channel of its own; its output is
  /// that collector's payload, which `parseTimerDetail` reads.
  static List<String> timerDetail(
    String unit, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.timerUnit, unit);
    return [
      ...manager._head,
      'show',
      '-p',
      'TimersCalendar',
      '-p',
      'TimersMonotonic',
      '-p',
      'RandomizedDelayUSec',
      '--',
      unit,
    ];
  }

  /// `systemctl cat -- <unit>`: the unit file and its drop-ins, each
  /// after a `# <path>` line (SVC-07, 03 §7.5).
  static List<String> unitFile(
    String unit, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, unit);
    return [...manager._head, 'cat', '--', unit];
  }

  /// `systemctl show` of [kUnitResourceProperties] for [unit] (SVC-08,
  /// 03 §7.5); [parseUnitResources] reads the output. `LoadState` comes
  /// first: `show` exits 0 for a unit it cannot find and prints defaults,
  /// so only `LoadState=not-found` says the unit is gone.
  static List<String> unitResources(
    String unit, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, unit);
    return [
      ...manager._head,
      'show',
      '--property=LoadState,${kUnitResourceProperties.join(',')}',
      '--',
      unit,
    ];
  }

  /// `systemctl list-sockets --all` as [format] (SVC-10, 03 §7.5);
  /// [parseUnitSockets] reads either shape.
  static List<String> unitSockets(
    UnitTableFormat format, {
    UnitManager manager = const UnitManager.system(),
  }) => [
    ...manager._head,
    'list-sockets',
    '--all',
    ...switch (format) {
      UnitTableFormat.json => const ['--output=json'],
      UnitTableFormat.text => const ['--no-legend'],
    },
  ];

  /// `systemctl --no-ask-password start -- <unit>` for "run timer now"
  /// (JOB-08, 03 §7.7, M13): starts the unit the timer activates, with
  /// SVC-03's guards. [activates] is the timer's `Unit=`, any unit but a
  /// timer [R: systemd.timer(5)]; the caller follows its journal with
  /// [journalctl]'s `unit`, `since` and [JournalOrder.follow].
  static List<String> timerStart(
    String activates, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, activates);
    if (activates.endsWith('.timer')) {
      throw HostCommandError('a timer activates no timer', argument: activates);
    }
    return systemctl(SystemctlVerb.start, activates, manager: manager);
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

  /// PRC-04 and PRC-05's read of process [pid] (03 §7.2), as the login
  /// user: its working directory, its `status` counters, its cgroups, its
  /// limits, how many files it holds open and its environment, each
  /// after a `== <section>` line `parseProcessDetail` reads. The working
  /// directory, descriptors and environment, which the kernel shows only
  /// to the owner and root, hold `== denied` when unreadable; `status`,
  /// `cgroup` and `limits` are readable by anyone who sees the process.
  /// The environment comes last, an entry a line: a value's newlines
  /// print as `\x01` so they cannot split it, and the cap counts entries.
  /// A value's own `\x01` byte comes back as a newline, the one loss
  /// this accepts.
  /// It exits as [startTicks] does when the process is
  /// gone or unreadable, and [kProcessDetailReused] when its start ticks
  /// are not [startTicks]: the PID names another process now.
  static List<String> processDetail(int pid, int startTicks) {
    if (pid <= 0) {
      throw HostCommandError('pid must be positive', argument: '$pid');
    }
    if (startTicks < 0) {
      throw HostCommandError('negative start ticks', argument: '$startTicks');
    }
    return [
      'sh',
      '-c',
      _kProcessDetailScript,
      'klabautermann-process',
      '$pid',
      '$startTicks',
    ];
  }

  static const _kProcessDetailScript =
      '${kStartTicksFunction}klab_ticks "\$1" || exit \$?\n'
      '[ "\$KT" = "\$2" ] || exit $kProcessDetailReused\n'
      'p=/proc/\$1\n'
      "echo '$kProcessDetailMarker cwd'\n"
      "readlink \"\$p/cwd\" 2>/dev/null || echo '$kProcessDetailDenied'\n"
      "echo '$kProcessDetailMarker status'\n"
      "grep -E '^(Threads|VmSwap|voluntary_ctxt_switches|"
      "nonvoluntary_ctxt_switches):' \"\$p/status\" 2>/dev/null\n"
      "echo '$kProcessDetailMarker cgroup'\n"
      'head -n 64 "\$p/cgroup" 2>/dev/null\n'
      "echo '$kProcessDetailMarker limits'\n"
      'cat "\$p/limits" 2>/dev/null\n'
      "echo '$kProcessDetailMarker fds'\n"
      'if ls "\$p/fd" >/dev/null 2>&1; then ls -1 "\$p/fd" | wc -l; '
      "else echo '$kProcessDetailDenied'; fi\n"
      "echo '$kProcessDetailMarker environ'\n"
      'if e=\$(tr \'\\n\\000\' \'\\001\\n\' <"\$p/environ" 2>/dev/null); then '
      'printf \'%s\\n\' "\$e" | head -n $kProcessEnvironLimit; '
      "else echo '$kProcessDetailDenied'; fi\n"
      'exit 0';

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
  static List<String> timerActivates(
    String timer, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, timer);
    return [
      ...manager._head,
      'show',
      '--property=Unit',
      '--value',
      '--',
      timer,
    ];
  }

  /// Prints systemd's load state of [unit] (`loaded`, `not-found`, ...),
  /// for an operation's re-validation (03 §8.5): a unit that no longer
  /// loads is not acted on.
  static List<String> unitLoadState(
    String unit, {
    UnitManager manager = const UnitManager.system(),
  }) {
    _check(ArgValidators.unitName, unit);
    return [
      ...manager._head,
      'show',
      '--property=LoadState',
      '--value',
      '--',
      unit,
    ];
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
  /// the kernel log (`-k -b`), unit, identifier, the current boot or
  /// another [boot], priority floor, time range, resume cursor, window size ([lines]),
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
    JournalBoot? boot,
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
    if (boot != null && currentBoot) {
      throw const HostCommandError('two boots named');
    }
    final bootArg = boot?._wire;
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
      if (bootArg != null) ...[
        '-b',
        bootArg,
      ] else if (kernel || currentBoot)
        '-b',
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

  /// The host's syslog line for one action (SAF-13, 03 §8.10):
  /// `logger -t klabautermann -- '<action> <target> by <device>'`, without
  /// "by" when [device] is blank. Each part loses its control characters
  /// and is capped at [kAuditLinePartMax] characters, so a target name
  /// cannot forge a second line or flood the journal; `--` keeps a part
  /// that starts with `-` a message.
  static List<String> auditLine(String action, String target, String device) {
    String clean(String part) {
      final text = part.replaceAll(_controlCharacters, ' ').trim();
      return text.length > kAuditLinePartMax
          ? text.substring(0, kAuditLinePartMax).trimRight()
          : text;
    }

    final words = [clean(action), clean(target)];
    if (words.any((word) => word.isEmpty)) {
      throw HostCommandError('an empty audit line part');
    }
    final by = clean(device);
    return [
      'logger',
      '-t',
      'klabautermann',
      '--',
      by.isEmpty ? words.join(' ') : '${words.join(' ')} by $by',
    ];
  }

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

  /// `journalctl --list-boots` (LOG-09, 03 §7.6), as JSON on systemd
  /// [kListBootsJsonSystemd] and later, else the text table;
  /// `parseJournalBoots` reads either.
  static List<String> journalBoots(JournalBootsFormat format) => [
    'journalctl',
    '--list-boots',
    '--no-pager',
    if (format == JournalBootsFormat.json) ...['-o', 'json'],
  ];

  /// BOOT-02's ends of the boots before the current one, at most
  /// [kBootEndsRead], one `<boot id> clean|unclean|unknown` line each:
  /// clean when the boot's last journal lines show journald stopping or
  /// a shutdown target, unknown when the system journal is not readable
  /// for it (no message from PID 1), as for a user outside the journal
  /// groups. `parseBootEnds` reads it. Each `journalctl` reads no
  /// stdin, which is the loop's list of boot IDs.
  static List<String> bootEnds() => const ['sh', '-c', _kBootEndsScript];

  static const _kBootEndsScript =
      'ids=\$(journalctl --list-boots --no-pager 2>/dev/null '
      "| awk 'length(\$2) == 32 { print \$2 }'); "
      'n=\$(printf "%s\\n" "\$ids" | grep -c .); '
      '[ "\$n" -gt 1 ] || exit 0; '
      'printf "%s\\n" "\$ids" | head -n \$((n - 1)) '
      '| tail -n $kBootEndsRead | while read -r id; do '
      'if [ -z "\$(journalctl -b "\$id" -q -n 1 -o cat --no-pager _PID=1 '
      '</dev/null 2>/dev/null)" ]; then echo "\$id unknown"; continue; fi; '
      'if journalctl -b "\$id" -q -n 40 -o cat --no-pager </dev/null 2>/dev/null '
      "| grep -qE 'Journal stopped|Reached target .*(Reboot|Power-Off|Halt|Shutdown)'; "
      'then echo "\$id clean"; else echo "\$id unclean"; fi; done';

  /// BOOT-03's read: the running kernel's release, then the module
  /// directories of the kernels installed. `parseKernels` reads it.
  static List<String> kernels() => const ['sh', '-c', _kKernelsScript];

  static const _kKernelsScript =
      'uname -r; echo "$kKernelsMarker"; '
      'ls -1 /lib/modules 2>/dev/null || ls -1 /usr/lib/modules 2>/dev/null; '
      'exit 0';

  /// NET-04's read: the listening TCP and UDP sockets with their
  /// processes from `ss -Htulpn`, or BusyBox's `netstat -tulpn` where
  /// there is no `ss`, then the cgroups of each process they name, so the
  /// app can tell the systemd unit or container behind a port. The login
  /// user sees only its own processes' sockets' owners.
  /// `parseListeningPorts` reads it.
  static List<String> listeningPorts() => const [
    'sh',
    '-c',
    _kListeningPortsScript,
  ];

  static const _kListeningPortsScript =
      'if command -v ss >/dev/null 2>&1; then '
      'echo "$kPortsToolMarker ss"; o=\$(ss -Htulpn 2>/dev/null); '
      'elif command -v netstat >/dev/null 2>&1; then '
      'echo "$kPortsToolMarker netstat"; o=\$(netstat -tulpn 2>/dev/null); '
      'else echo "$kPortsToolMarker none"; o=; fi; '
      "printf '%s\\n' \"\$o\"; "
      "for p in \$(printf '%s\\n' \"\$o\" | grep -oE 'pid=[0-9]+| [0-9]+/' "
      "| tr -dc '0-9\\n' | sort -un); do "
      'echo "$kPortsCgroupMarker \$p"; cat "/proc/\$p/cgroup" 2>/dev/null; '
      'done; exit 0';

  /// CPU-07's read: the CPUs this login may run on, `lscpu`'s fields in
  /// the C locale, whose names it translates otherwise, and the
  /// `/proc/cpuinfo` lines that name the model and place each CPU, for a
  /// host without `lscpu` (BusyBox). `parseCpuTopology` reads it. Only
  /// those lines are kept: the flags make the file about 1.5 KiB a CPU.
  static List<String> cpuTopology() => const ['sh', '-c', _kCpuTopologyScript];

  static const _kCpuTopologyScript =
      'echo "$kCpuNprocMarker"; '
      'nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; '
      'echo "$kCpuLscpuMarker"; LC_ALL=C lscpu -J 2>/dev/null; '
      'echo "$kCpuInfoMarker"; '
      "grep -E '^(processor|model name|cpu model|cpu|physical id|core id)"
      "[[:space:]]*:' /proc/cpuinfo 2>/dev/null; "
      'exit 0';

  /// NET-02 and NET-03's read: each interface's sysfs files as
  /// `<name>/<file>:<value>` lines from one `grep` (a down link's `speed`
  /// fails to read and is left out), the interfaces backed by a device,
  /// the addresses from `ip -j addr` or, where `ip` has no JSON
  /// (BusyBox), `ip -o addr`, the count of TCP sockets per state from
  /// `/proc/net/tcp` and `tcp6`, and `/proc/net/sockstat`. Everything
  /// under `/proc/net` is the reader's network namespace's (D50).
  /// `parseInterfaces` reads it.
  static List<String> interfaces() => const ['sh', '-c', _kInterfacesScript];

  static const _kInterfacesScript =
      'echo "$kNetLinksMarker"; '
      "cd /sys/class/net 2>/dev/null && grep -s -H '' -- "
      '*/operstate */mtu */address */speed '
      '*/statistics/rx_bytes */statistics/tx_bytes '
      '*/statistics/rx_errors */statistics/tx_errors '
      "*/statistics/rx_dropped */statistics/tx_dropped; "
      'echo "$kNetPhysicalMarker"; '
      '[ "\$PWD" = /sys/class/net ] && '
      'for d in */device; do [ -e "\$d" ] && echo "\${d%/device}"; done; '
      'echo "$kNetAddrMarker"; ip -j addr 2>/dev/null || ip -o addr 2>/dev/null; '
      'echo "$kNetTcpMarker"; '
      "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | "
      "awk '\$4 ~ /^[0-9A-F][0-9A-F]\$/ { n[\$4]++ } "
      "END { for (s in n) print s, n[s] }'; "
      'echo "$kNetSockstatMarker"; '
      'cat /proc/net/sockstat /proc/net/sockstat6 2>/dev/null; '
      'exit 0';

  /// NET-06's read (03 §7.4), run as root, since every tool here needs
  /// it: `ufw status verbose`, firewalld's state and its zones,
  /// `nft -j list ruleset`, and `iptables-save` and `ip6tables-save`,
  /// each after its marker and only where installed, each cut to
  /// [kFirewallLinesKept] lines. `parseFirewall` reads it.
  static List<String> firewall() => const ['sh', '-c', _firewall];

  static const _firewall =
      '''
# ufw's labels are translated; the parser reads the English ones.
export LC_ALL=C
keep() { head -n $kFirewallLinesKept; }
if command -v ufw >/dev/null 2>&1; then
  echo '$kFirewallUfwMarker'
  ufw status verbose 2>&1 | keep
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  s=\$(firewall-cmd --state 2>&1)
  echo "$kFirewallFirewalldMarker \$s"
  [ "\$s" = running ] && firewall-cmd --list-all-zones 2>&1 | keep
fi
if command -v nft >/dev/null 2>&1; then
  echo '$kFirewallNftMarker'
  nft -j list ruleset 2>/dev/null | keep
fi
if command -v iptables-save >/dev/null 2>&1; then
  echo '$kFirewallIptablesMarker'
  iptables-save 2>/dev/null | keep
fi
if command -v ip6tables-save >/dev/null 2>&1; then
  echo '$kFirewallIp6tablesMarker'
  ip6tables-save 2>/dev/null | keep
fi
exit 0''';

  /// SEC-01's read (03 §7.10), run as root, since `sshd -T` loads the
  /// host keys: the effective configuration for this connection, with the
  /// `Match` blocks that apply to [user] connecting from
  /// [sshConnection]'s client to its local address and port. sudo drops
  /// `$SSH_CONNECTION`, so both come from the probe. sshd before 7.x
  /// refuses `laddr` and `lport`, so the read retries without them, then
  /// without `-C`, where no `Match` block applies; a [user] or
  /// [sshConnection] that is not one leaves `-C` out. The client's
  /// address doubles as its host name, which is what sshd matches with
  /// its default `UseDNS no`. `parseSshdPosture` reads it.
  static List<String> sshdPosture({String? user, String? sshConnection}) {
    final fields = sshConnection?.trim().split(RegExp(r'\s+'));
    String full = '', basic = '';
    if (user != null &&
        ArgValidators.userName(user) == null &&
        fields != null &&
        fields.length == 4 &&
        _ipAddress.hasMatch(fields[0]) &&
        _ipAddress.hasMatch(fields[2]) &&
        _port.hasMatch(fields[3]) &&
        int.parse(fields[3]) <= 65535) {
      basic = 'user=$user,host=${fields[0]},addr=${fields[0]}';
      full = '$basic,laddr=${fields[2]},lport=${fields[3]}';
    }
    return ['sh', '-c', _sshdPosture, 'sh', full, basic];
  }

  static final _ipAddress = RegExp(r'^[0-9A-Fa-f.:]{2,45}$');
  static final _port = RegExp(r'^[1-9][0-9]{0,4}$');

  static const _sshdPosture =
      '''
s=
for p in "\$(command -v sshd 2>/dev/null)" /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
  if [ -n "\$p" ] && [ -x "\$p" ]; then s=\$p; break; fi
done
[ -n "\$s" ] || { echo '$kSshdMarker missing'; exit 0; }
if [ -n "\$1" ] && o=\$("\$s" -T -C "\$1" 2>/dev/null); then m=full
elif [ -n "\$2" ] && o=\$("\$s" -T -C "\$2" 2>/dev/null); then m=basic
elif o=\$("\$s" -T 2>/dev/null); then m=none
else
  echo '$kSshdMarker failed'
  "\$s" -T 2>&1 | head -n 5
  exit 0
fi
echo "$kSshdMarker \$m"
printf '%s\\n' "\$o"''';

  /// DSK-05 and DSK-14's read: every mount's source, type and options,
  /// from `findmnt -J -l` (util-linux 2.27+) or `/proc/self/mounts`, then
  /// the swap devices from `/proc/swaps`. `parseMounts` reads it.
  static List<String> mounts() => const ['sh', '-c', _kMountsScript];

  static const _kMountsScript =
      'if command -v findmnt >/dev/null 2>&1 && '
      'out=\$(findmnt -J -l -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null); '
      'then echo "$kMountsFindmntMarker"; printf "%s\\n" "\$out"; '
      'else echo "$kMountsProcMarker"; cat /proc/self/mounts 2>/dev/null; fi; '
      'echo "$kMountsSwapsMarker"; cat /proc/swaps 2>/dev/null; exit 0';

  /// DSK-07's read of one folder (03 §7.3): `du -x -k -a -d 1` over
  /// [path] on its own filesystem, read-only, the folder's total and
  /// each entry in it with its size in KiB, largest first and at most
  /// [kDiskUsageEntries] of them, each marked `d` for a folder (not a
  /// symlink) or `f` for anything else; then [kDiskUsageErrorsMarker]
  /// and the first 2 KiB of what `du` printed on stderr, such as the
  /// folders it could not read, in the C locale the parser matches; the
  /// rest is drained, so `du` walks the whole folder. Portable to BusyBox and BSD `du`, which
  /// take the same flags. `parseDiskUsage` reads it. [path] is absolute
  /// and normalized, without a trailing slash unless it is `/`.
  static List<String> diskUsage(String path) {
    _checkDiskUsagePath(path);
    return ['sh', '-c', _kDiskUsageScript, 'klabautermann-du', path];
  }

  /// Exports the whole filesystem under [path] in ncdu's JSON format on
  /// stdout (DSK-07, 03 §7.3), without crossing into other filesystems,
  /// for `DiskUsageExportReader`. Both tools stay quiet without a
  /// terminal when they export to stdout.
  static List<String> diskUsageExport(String path, DiskUsageExportTool tool) {
    _checkDiskUsagePath(path);
    return switch (tool) {
      DiskUsageExportTool.ncdu => ['ncdu', '-x', '-o', '-', path],
      DiskUsageExportTool.gdu => ['gdu', '-x', '-o-', path],
    };
  }

  static void _checkDiskUsagePath(String path) {
    _check(ArgValidators.absolutePath, path);
    if (path.contains('//') || (path.length > 1 && path.endsWith('/'))) {
      throw HostCommandError('path not normalized', argument: path);
    }
  }

  // fd 3 carries the listing past the command substitution, which keeps
  // only stderr; a name with a newline in it splits into lines the
  // parser drops, as `du` has no way to quote it.
  static const _kDiskUsageScript =
      'export LC_ALL=C\n'
      't=\$(printf "\\t")\n'
      'exec 3>&1\n'
      'err=\$( { du -x -k -a -d 1 -- "\$1" | sort -rn | '
      'head -n ${kDiskUsageEntries + 1} | '
      'while IFS= read -r l; do p=\${l#*"\$t"}; '
      'if [ -d "\$p" ] && [ ! -L "\$p" ]; then k=d; else k=f; fi; '
      'printf "%s\\t%s\\n" "\$k" "\$l" >&3; done; } 2>&1 | '
      '{ head -c 2048; cat >/dev/null; } )\n'
      'exec 3>&-\n'
      'echo "$kDiskUsageErrorsMarker"\n'
      'printf "%s\\n" "\$err"\n'
      'exit 0';

  /// The files under `/var/log` (LOG-08, 03 §7.6); `parseLogFiles`
  /// reads the output.
  static List<String> logFiles() => const [
    'sh',
    '-c',
    _kLogFilesScript,
    'klabautermann-logs',
  ];

  /// The last [lines] lines of a compressed rotated log (LOG-08, 03
  /// §7.6), through `zcat` or `xzcat`; never followed, since a rotated
  /// file no longer grows. An uncompressed file reads through [tail].
  static List<String> rotatedTail(String path, {required int lines}) {
    _check(ArgValidators.absolutePath, path);
    if (lines < 0) throw const HostCommandError('negative line count');
    final tool = switch (LogCompression.of(path)) {
      LogCompression.gzip => 'zcat',
      LogCompression.xz => 'xzcat',
      LogCompression.none => throw HostCommandError(
        'not a compressed log',
        argument: path,
      ),
    };
    return [
      'sh',
      '-c',
      _kRotatedTailScript,
      'klabautermann-rotated',
      tool,
      path,
      '$lines',
    ];
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
    RunAsTool tool = RunAsTool.installed,
  }) {
    if (command.trim().isEmpty || command.codeUnits.contains(0)) {
      throw HostCommandError('not a command', argument: command);
    }
    if (asUser == null) return ['sh', '-c', command];
    _check(ArgValidators.userName, asUser);
    return switch (tool) {
      RunAsTool.installed => [
        'sh',
        '-c',
        _kRunAsScript,
        'klabautermann-run-as',
        asUser,
        command,
      ],
      RunAsTool.runuser => ['runuser', '-u', asUser, '--', 'sh', '-c', command],
      RunAsTool.su => ['su', '-s', '/bin/sh', '-c', command, asUser],
    };
  }

  /// The package check (03 §7.8, PKG-01 to PKG-03), as the login user
  /// and from cached metadata only: it never refreshes package lists
  /// (PKG-05 does, in admin mode). It reads the first manager it finds
  /// and prints `parsePackageCheck`'s sections: `== manager`, `== cache`
  /// (the metadata's age as epoch seconds), `== updates` and, where the
  /// manager has one, `== security`, each body ended by `== rc <status>`,
  /// then `== reboot required|no|unknown` with the packages that asked.
  /// apt simulates a `dist-upgrade`, since `upgrade` keeps back updates
  /// that bring new packages, as a kernel's do.
  static List<String> packageCheck() => const ['sh', '-c', _packageCheck];

  /// The first package manager the check would read, by name, as
  /// `parsePackageCheck` names them: what PKG-05's refresh plans for.
  static List<String> packageManagerName() => const [
    'sh',
    '-c',
    _packageManagerName,
  ];

  // The same order as [_packageCheck]'s branches; a test pins the two.
  static const _packageManagerName =
      'for m in apt-get dnf zypper pacman apk; do '
      'command -v "\$m" >/dev/null 2>&1 && { echo "\${m%-get}"; exit 0; }; '
      'done; exit 1';

  /// The host's own name, as SYS-03's typed confirmation asks for it.
  static List<String> hostname() => const ['uname', '-n'];

  /// SYS-03's [verb], run as root: `systemctl` where systemd runs the
  /// host ([systemd]), which queues the job and returns, otherwise the
  /// `reboot` and `poweroff` that BusyBox and sysvinit provide, which
  /// signal init and return.
  static List<String> power(PowerVerb verb, {required bool systemd}) =>
      systemd ? ['systemctl', verb.name] : [verb.name];

  /// PKG-05's refresh of [manager]'s package lists, run as root: what the
  /// check reads afterwards. pacman has none, since `pacman -Sy` without
  /// upgrading leaves a partly upgraded system, so it throws
  /// [HostCommandError].
  static List<String> packageRefresh(PackageManager manager) =>
      switch (manager) {
        PackageManager.apt => const ['apt-get', '-q', 'update'],
        PackageManager.dnf => const ['dnf', '-q', 'makecache'],
        PackageManager.zypper => const [
          'zypper',
          '--non-interactive',
          'refresh',
        ],
        PackageManager.apk => const ['apk', 'update'],
        PackageManager.pacman => throw const HostCommandError(
          'pacman lists refresh only with an upgrade',
        ),
      };

  /// PKG-04's restart check (03 §7.8), run as root, since the tools read
  /// every process's maps: the first of `needrestart -b`,
  /// `needs-restarting -s` and `zypper ps -sss` installed, after a
  /// `== tool <name>` line for `parseRestartCheck`, or `== tool none`.
  static List<String> restartCheck() => const ['sh', '-c', _restartCheck];

  static const _restartCheck =
      'if command -v needrestart >/dev/null 2>&1; then '
      'echo "== tool needrestart"; exec needrestart -b; '
      'elif command -v needs-restarting >/dev/null 2>&1; then '
      'echo "== tool needs-restarting"; exec needs-restarting -s; '
      'elif command -v zypper >/dev/null 2>&1; then '
      'echo "== tool zypper"; exec zypper ps -sss; '
      'else echo "== tool none"; fi';

  /// MEM-03's read (03 §7.1): the kills since boot from `/proc/vmstat`'s
  /// `oom_kill` (Linux 4.13+), then the current boot's kill lines from the
  /// kernel log, the journal's where the login user may read it, else
  /// `dmesg`, which `kernel.dmesg_restrict` may refuse. Only the newest
  /// [kOomLinesKept] are kept; `parseOomKills` reads them.
  static List<String> oomKills() => const ['sh', '-c', _oomKills];

  static const _oomKills =
      '''
echo "$kOomVmstatMarker \$(awk '\$1 == "oom_kill" { print \$2 }' /proc/vmstat 2>/dev/null)"
kernel() {
  if command -v journalctl >/dev/null 2>&1 &&
    journalctl -k -b -q -n 1 --no-pager 2>/dev/null | grep -q .; then
    echo '$kOomSourceMarker journal'
    journalctl -k -b -q --no-pager -o short-unix 2>/dev/null
  else
    echo '$kOomSourceMarker dmesg'
    dmesg 2>/dev/null
  fi
}
kernel | awk -v keep=$kOomLinesKept '
  NR == 1 { print; next }
  { n++ }
  /Killed process [0-9]+ \\(|oom-kill:/ { kept[k++ % keep] = \$0 }
  END {
    for (i = k > keep ? k - keep : 0; i < k; i++) print kept[i % keep]
    print "$kOomReadMarker " n + 0
  }'
exit 0''';

  static const _packageCheck = r'''
have() { command -v "$1" >/dev/null 2>&1; }
mtime() { stat -c %Y "$1" 2>/dev/null; }
if have apt-get; then
  echo '== manager apt'
  echo "== cache $(mtime /var/cache/apt/pkgcache.bin)"
  echo '== updates'
  apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>&1; echo "== rc $?"
elif have dnf; then
  echo '== manager dnf'
  echo "== cache $(for f in /var/cache/dnf/*.solv /var/cache/libdnf5/*/solv/*.solv; do mtime "$f"; done | sort -n | tail -n 1)"
  echo '== updates'
  dnf -q --cacheonly check-update 2>&1; echo "== rc $?"
  echo '== security'
  dnf -q --cacheonly updateinfo list --security 2>&1; echo "== rc $?"
elif have zypper; then
  echo '== manager zypper'
  echo "== cache $(for f in /var/cache/zypp/raw/*/repodata/repomd.xml; do mtime "$f"; done | sort -n | tail -n 1)"
  echo '== updates'
  zypper --non-interactive --no-refresh -q lu 2>&1; echo "== rc $?"
  echo '== security'
  zypper --non-interactive --no-refresh -q lp -g security 2>&1; echo "== rc $?"
elif have pacman; then
  echo '== manager pacman'
  echo "== cache $(mtime /var/lib/pacman/sync)"
  echo '== updates'
  pacman -Qu 2>&1; echo "== rc $?"
elif have apk; then
  echo '== manager apk'
  echo "== cache $(for f in /var/cache/apk/APKINDEX.*; do mtime "$f"; done | sort -n | tail -n 1)"
  echo '== updates'
  apk version -l '<' 2>&1; echo "== rc $?"
else
  echo '== manager none'
fi
if [ -e /var/run/reboot-required ]; then
  echo '== reboot required'
  cat /var/run/reboot-required.pkgs 2>/dev/null
elif have needs-restarting; then
  needs-restarting -r >/dev/null 2>&1
  case $? in 0) echo '== reboot no' ;; 1) echo '== reboot required' ;; *) echo '== reboot unknown' ;; esac
elif [ -d /var/lib/dpkg ]; then
  echo '== reboot no'
else
  echo '== reboot unknown'
fi
''';

  /// ACC-01 and ACC-02's read: the accounts and groups through `getent`,
  /// which sees directory users too, or the files where it is missing,
  /// then the logins `who` lists. Each part is capped, so a directory
  /// that enumerates thousands stays a bounded read; `parseAccounts`
  /// counts what went past its own limit. `who`'s errors join its
  /// output, so a host without `who` reads as logins unknown rather than
  /// as no one logged in.
  static List<String> accounts() => const ['sh', '-c', _accounts];

  static const _accounts =
      '{ getent passwd || cat /etc/passwd; } 2>/dev/null | head -n 5000; '
      'echo "$kAccountsGroupMarker"; '
      '{ getent group || cat /etc/group; } 2>/dev/null | head -n 5000; '
      'echo "$kAccountsWhoMarker"; '
      'who 2>&1 | head -n 500; exit 0';

  /// `smartctl --scan-open -j`: the drives smartctl can open, with the
  /// device type it would read each as (03 §7.11, HW-04).
  static List<String> smartScan() => const ['smartctl', '--scan-open', '-j'];

  /// `smartctl -n standby -a -j -d <type> <device>` for one drive's
  /// health (03 §7.11, HW-04): a drive that is spun down is left asleep,
  /// and smartctl says so instead of reading it. [device] and [type] come
  /// from [smartScan]'s output, so both are checked before use.
  static List<String> smartRead(String device, String type) {
    _check(_smartDevice, device);
    _check(_smartType, type);
    return ['smartctl', '-n', 'standby', '-a', '-j', '-d', type, device];
  }

  static String? _smartDevice(String value) {
    if (!_smartDevicePattern.hasMatch(value) || value.contains('..')) {
      return 'not a device node';
    }
    return null;
  }

  static String? _smartType(String value) =>
      _smartTypePattern.hasMatch(value) ? null : 'not a smartctl device type';

  /// A device node: `/dev/sda`, `/dev/nvme0`, `/dev/bus/0`.
  static final _smartDevicePattern = RegExp(r'^/dev/[A-Za-z0-9._/-]{1,64}$');

  /// A `-d` type as `--scan-open` prints it: `sat`, `nvme`,
  /// `megaraid,0`, `sat+megaraid,1`.
  static final _smartTypePattern = RegExp(r'^[a-z0-9][a-z0-9_,+-]{0,31}$');

  /// IMG-05's registry read (03 §7.14, D68): for each of [targets], a
  /// manifest `HEAD` by `curl` on the host, so it goes out through the
  /// host's network and proxy and spends no Docker Hub quota. Where the
  /// first answer names a `Bearer` realm over `https`, the script fetches
  /// that realm's anonymous pull token and asks again; the token goes to
  /// `curl` on a pipe (`-H @-`), never in an argument another process
  /// could list. Where the registry still wants credentials, `docker
  /// buildx imagetools inspect` resolves the reference with the host
  /// CLI's own credentials. `parseRegistryHeads` reads the output.
  static List<String> registryHeads(List<RegistryHeadTarget> targets) {
    if (targets.isEmpty || targets.length > kRegistryHeadsMax) {
      throw HostCommandError(
        'between 1 and $kRegistryHeadsMax images',
        argument: '${targets.length}',
      );
    }
    return [
      'sh',
      '-c',
      _registryHeadsScript,
      'hws-registry',
      for (final target in targets) ...[
        _checked(_registryHost, target.registry),
        _checked(_registryRepository, target.repository),
        _checked(_registryTag, target.tag),
        _checked(_registryReference, target.reference),
      ],
    ];
  }

  // Plain HTTP only for a registry on the host itself, as Docker allows.
  // curl's own header limit bounds a `HEAD`; `head -c` bounds the token
  // body and buildx's output. The token is read from the realm's JSON
  // with sed, since jq is rarely installed.
  static const _registryHeadsScript =
      r'''command -v curl >/dev/null 2>&1 || { echo "'''
      '$kRegistryNoCurlMarker'
      r'''"; exit 0; }
a=application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json
b=; docker buildx version >/dev/null 2>&1 && b=1
while [ $# -ge 4 ]; do
r=$1; p=$2; t=$3; f=$4; shift 4
case $r in localhost|localhost:*|127.0.0.1|127.0.0.1:*) s=http;; *) s=https;; esac
u="$s://$r/v2/$p/manifests/$t"
echo "'''
      '$kRegistryImageMarker'
      r''' $f"
h=$(curl -sS -I --max-time 20 -H "Accept: $a" "$u" 2>&1); e=$?
c=$(printf '%s\n' "$h" | tr -d '\r' | grep -i '^www-authenticate: *bearer' | head -n 1)
if [ -n "$c" ]; then
m=$(printf '%s' "$c" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
v=$(printf '%s' "$c" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
case $m in https://*)
k=$(curl -sS --max-time 20 -G --data-urlencode "service=$v" --data-urlencode "scope=repository:$p:pull" "$m" 2>/dev/null | head -c 16384 | sed -n 's/.*"\(access_\)\{0,1\}token" *: *"\([^"]*\)".*/\2/p' | head -n 1)
if [ -n "$k" ]; then
h=$(printf 'Authorization: Bearer %s\n' "$k" | curl -sS -I --max-time 20 -H @- -H "Accept: $a" "$u" 2>&1); e=$?
fi;;
esac
fi
echo "'''
      '$kRegistryHeadMarker'
      r''' $e"
printf '%s\n' "$h" | tr -d '\r' | grep -iE '^(HTTP/|docker-content-digest:|content-type:|ratelimit-|www-authenticate:)'
x=$(printf '%s\n' "$h" | tr -d '\r' | grep '^HTTP/' | tail -n 1 | cut -d ' ' -f 2)
if [ "$x" = 401 ] || [ "$x" = 403 ]; then
if [ -n "$b" ]; then
o=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$f" 2>&1); y=$?
echo "'''
      '$kRegistryCliMarker'
      r''' $y"
printf '%s\n' "$o" | head -c '''
      '$kRegistryCliMaxBytes'
      r'''; echo
else echo "'''
      '$kRegistryCliMarker'
      r''' missing"; fi
fi
done
exit 0''';

  static String _checked(String? Function(String) validator, String value) {
    _check(validator, value);
    return value;
  }

  static String? _registryHost(String value) =>
      _registryHostPattern.hasMatch(value) ? null : 'not a registry host';

  static String? _registryRepository(String value) =>
      value.split('/').every(_registryPathComponent.hasMatch)
      ? null
      : 'not a repository path';

  static String? _registryTag(String value) =>
      _registryTagPattern.hasMatch(value) ? null : 'not an image tag';

  static String? _registryReference(String value) =>
      _registryReferencePattern.hasMatch(value)
      ? null
      : 'not an image reference';

  static final _registryHostPattern = RegExp(r'^[a-zA-Z0-9.-]+(?::[0-9]+)?$');
  static final _registryPathComponent = RegExp(
    r'^[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*$',
  );
  static final _registryTagPattern = RegExp(r'^\w[\w.-]{0,127}$');

  /// docker_plans' reference shape: an optional host, lower-case path
  /// components and a tag; no digest, since a pinned image is not checked.
  static final _registryReferencePattern = RegExp(
    r'^(?:[a-zA-Z0-9.-]+(?::[0-9]+)?/)?'
    r'[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*'
    r'(?:/[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*)*'
    r'(?::\w[\w.-]{0,127})?$',
  );

  /// `crontab -l -u <user>` for the jobs view's user switch (03 §7.7).
  static List<String> crontabList(String user) {
    _check(ArgValidators.userName, user);
    return ['crontab', '-l', '-u', user];
  }

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

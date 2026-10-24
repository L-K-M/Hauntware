/// The HWS/1 collector vocabulary (03 §6.2, §6.4).
///
/// Collector names are the only words a client may place after `hw_t` or as
/// the command of `hw_o`; they come from this fixed enum so the assembled
/// program and every request share one spelling. Wire names must match
/// [collectorWireNamePattern].
library;

/// Wire-name grammar for collectors (03 §6.2).
final collectorWireNamePattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// The sampler a collector's fragment ships in (03 §6.2 "Two samplers").
///
/// The fast sampler runs only builtin collectors over `/proc` and `/sys`
/// counters that cannot block, so a hung tool can never stall CPU graphs.
/// The slow sampler runs forking and potentially blocking tools under
/// `timeout 10` when `timeout` exists.
enum SamplerKind {
  /// Builtin-only collectors (03 §6.2).
  fast,

  /// Forking collectors, guarded by `timeout` where available (03 §6.2).
  slow,
}

/// A validator for one `hw_o` argument: returns `null` when [value] is
/// acceptable, else a short reason. Validators run before quoting so a bad
/// argument is refused before any text is produced (03 §8.8).
typedef ArgValidator = String? Function(String value);

/// A collector the HWS/1 program can run (03 §6.4).
enum Collector {
  /// The capability probe (03 §6.1). Emits one section per probe area on
  /// the slow sampler; the client requests it once after connect.
  probe(SamplerKind.slow, [], guardedCommands: 17),

  /// Fleet-row metrics: total cpu line, the meminfo subset, loadavg and
  /// the interface counters D48 keeps (03 §6.4, fast sampler).
  overview(SamplerKind.fast, [], guardedCommands: 0),

  /// Focused-server metrics: overview plus per-core busy and idle jiffies,
  /// btime, the diskstats counters D48 keeps, PSI averages, uptime and
  /// the ZFS ARC (03 §6.4, fast sampler).
  core(SamplerKind.fast, [], guardedCommands: 0),

  /// Mount usage and inodes from `df -PT -B1` and `df -Pi` (03 §6.4, §7.3,
  /// slow sampler under `timeout`).
  fs(SamplerKind.slow, [], guardedCommands: 2),

  /// Host identity: `/etc/os-release`, `uname`, `hostnamectl --json=short`
  /// (03 §6.4, slow sampler).
  identity(SamplerKind.slow, [], guardedCommands: 2),

  /// Process list: at most `kProcsRowCap` rows from `/proc/<pid>/stat`
  /// and `status` with builtins, their `cmdline` through one `head|tr`
  /// pipeline, `ps` fallback (03 §7.2, D48, slow sampler while the view
  /// is visible).
  procs(SamplerKind.slow, [], guardedCommands: 3),

  /// systemd units and failed units (03 §6.4, §7.5).
  units(SamplerKind.slow, [], guardedCommands: 4),

  /// systemd timers (03 §6.4, §7.7).
  timers(SamplerKind.slow, [], guardedCommands: 2),

  /// The login user's own systemd units and failed units, from its user
  /// manager (03 §7.5, SVC-09).
  userUnits(SamplerKind.slow, [], guardedCommands: 4, wireName: 'user_units'),

  /// The login user's own systemd timers (03 §7.7, JOB-08).
  userTimers(SamplerKind.slow, [], guardedCommands: 2, wireName: 'user_timers'),

  /// Cron jobs: own `crontab -l`, `/etc/crontab`, `/etc/cron.d/*` and the
  /// `cron.{hourly,daily,weekly,monthly}` directory names (03 §6.4, §7.7).
  cron(SamplerKind.slow, [], guardedCommands: 1),

  /// One timer's `OnCalendar=` and monotonic triggers and its randomized
  /// delay from `systemctl show` (03 §7.7, D57), on demand only: its one
  /// argument is the timer unit (slow sampler).
  timerDetail(
    SamplerKind.slow,
    [ArgValidators.timerUnit],
    guardedCommands: 1,
    wireName: 'timer_detail',
  ),

  /// Detached-operation records for re-attach: both operation directories
  /// of 03 §7.17, at most `kOpsRecordCap` records each, each cut at
  /// `kOpsRecordBytes` (slow sampler, one guarded listing per directory).
  ops(SamplerKind.slow, [], guardedCommands: 2);

  const Collector(
    this.sampler,
    this.argValidators, {
    required this.guardedCommands,
    this._wireName,
  });

  /// Which sampler's program contains this collector's fragment.
  final SamplerKind sampler;

  /// An upper bound on the guarded commands (`hw_run`, `hw_qrun`) one run
  /// of this collector's fragment starts, each bounded by `timeout 10`
  /// when the host has `timeout` (03 §6.2). A slow request's deadline is
  /// derived from the sum over its collectors (D47). The count is the
  /// calls written in the fragment, none of them inside a loop; where
  /// calls sit on exclusive branches (`procs`' `head` or `ps`, the JSON or
  /// text calls of `units` and `timers`) only one branch runs, so the
  /// bound is high by those. A test ties each count to the fragment text.
  /// The fast collectors run builtins only and declare 0.
  final int guardedCommands;

  /// Positional validators for `hw_o` arguments; the request is refused
  /// when the argument count differs from this list's length or any
  /// validator rejects its argument. A collector without arguments reads
  /// the same in a tick and in a bare `hw_o <seq> <name>`; one with
  /// arguments is requested through `hw_o` only.
  final List<ArgValidator> argValidators;

  final String? _wireName;

  /// Wire name on `hw_t`/`hw_o`, in the program's `c_<name>` function and
  /// in `S` section markers: the enum name, unless the collector declares
  /// a snake_case one. Every wire name satisfies [collectorWireNamePattern].
  String get wireName => _wireName ?? name;

  /// Looks up a collector by wire name; `null` when unknown.
  static Collector? byName(String name) {
    for (final c in values) {
      if (c.wireName == name) return c;
    }
    return null;
  }
}

/// The 03 §8.8 argument vocabulary: one type-specific validator per kind of
/// interpolated value, applied before `quoteShellWord`.
abstract final class ArgValidators {
  /// systemd unit-name grammar (03 §7.5, §8.8): an optional `prefix@`
  /// template part, an instance part, then a known suffix.
  static String? unitName(String value) {
    if (value.isEmpty || value.length > 256) return 'unit name length';
    if (!_unitNamePattern.hasMatch(value)) return 'unit name grammar';
    return null;
  }

  /// POSIX login name (03 §8.8).
  static String? userName(String value) {
    if (!_userNamePattern.hasMatch(value)) return 'user name grammar';
    return null;
  }

  /// An absolute normalized path without NUL (03 §8.8).
  static String? absolutePath(String value) {
    if (value.isEmpty || value.codeUnits.contains(0)) return 'path has NUL';
    if (!value.startsWith('/')) return 'path not absolute';
    for (final part in value.split('/')) {
      if (part == '..') return 'path not normalized';
    }
    if (value.endsWith('/.') || value.contains('/./')) {
      return 'path not normalized';
    }
    return null;
  }

  /// A signal name from the fixed signal vocabulary (03 §8.8 "signal names
  /// (enum)").
  static String? signalName(String value) {
    if (!_signalNames.contains(value.toUpperCase())) return 'unknown signal';
    return null;
  }

  /// A non-negative decimal integer (pid, window size, count).
  static String? uint(String value) {
    if (value.isEmpty || value.length > 18) return 'not a non-negative int';
    for (final c in value.codeUnits) {
      if (c < 0x30 || c > 0x39) return 'not a non-negative int';
    }
    return null;
  }

  /// A syslog priority for `journalctl -p` (03 §7.6): a severity number
  /// 0..7 or one of the named levels journalctl accepts.
  static String? journalPriority(String value) {
    if (!_journalPriorities.contains(value.toLowerCase())) {
      return 'unknown journal priority';
    }
    return null;
  }

  /// A journald cursor for `journalctl --after-cursor` (03 §7.6): six
  /// `key=hex` fields joined by semicolons.
  static String? journalCursor(String value) {
    if (value.isEmpty || value.length > 512) return 'cursor length';
    if (!_journalCursorPattern.hasMatch(value)) return 'cursor grammar';
    return null;
  }

  /// A journald search pattern for `journalctl -g` (03 §7.6): any
  /// non-empty line without control bytes; the pattern is quoted, not
  /// validated as a regex.
  static String? journalGrep(String value) => _freeText(value, 'pattern');

  /// A syslog identifier for `journalctl -t` (03 §7.6): free text
  /// without control bytes, matched by journald as written.
  static String? syslogIdentifier(String value) =>
      _freeText(value, 'identifier');

  /// A timer unit for `timer_detail` (03 §7.7): the unit-name grammar
  /// with the `.timer` suffix.
  static String? timerUnit(String value) {
    final reason = unitName(value);
    if (reason != null) return reason;
    if (!value.endsWith('.timer')) return 'not a timer unit';
    return null;
  }

  /// A systemd calendar expression for `systemd-analyze calendar`
  /// (03 §7.7): free text without control bytes; `systemd-analyze` is
  /// the grammar authority, quoting happens after this check.
  static String? calendarExpression(String value) =>
      _freeText(value, 'calendar expression');

  /// Shared check for free-text arguments: non-empty, bounded, and free
  /// of control characters so no markup can leak into a command line.
  static String? _freeText(String value, String what) {
    if (value.isEmpty || value.length > 512) return 'bad $what';
    for (final c in value.codeUnits) {
      if (c < 0x20 || c == 0x7f) return 'control byte in $what';
    }
    return null;
  }
}

final _unitNamePattern = RegExp(
  '^[A-Za-z0-9:_.\\-]+(@[A-Za-z0-9:_.\\-]*)?\\.(service|socket|device|mount|'
  'automount|swap|target|path|timer|slice|scope)\$',
);

final _userNamePattern = RegExp(r'^[a-z_][a-z0-9_-]*[$]?$');

/// Syslog severities journalctl accepts for `-p` (syslog.h + names).
const _journalPriorities = {
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  'emerg',
  'alert',
  'crit',
  'err',
  'warning',
  'notice',
  'info',
  'debug',
};

/// journald cursor fields are `key=hex` pairs joined by `;`, keys from
/// `sibmtx` (sd_journal_seek_cursor).
final _journalCursorPattern = RegExp(r'^[a-z]+=[0-9a-f]+(;[a-z]+=[0-9a-f]+)*$');

/// Signal names a remote `kill -s` may carry (03 §8.8 "signal names
/// (enum)"). Kept to the portable POSIX list plus the usual Linux names.
const _signalNames = {
  'HUP',
  'INT',
  'QUIT',
  'ILL',
  'TRAP',
  'ABRT',
  'BUS',
  'FPE',
  'KILL',
  'USR1',
  'SEGV',
  'USR2',
  'PIPE',
  'ALRM',
  'TERM',
  'STKFLT',
  'CHLD',
  'CONT',
  'STOP',
  'TSTP',
  'TTIN',
  'TTOU',
  'URG',
  'XCPU',
  'XFSZ',
  'VTALRM',
  'PROF',
  'WINCH',
  'IO',
  'PWR',
  'SYS',
};

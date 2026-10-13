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
///
/// `procs`, `units`, `timers` and `cron` join with their fragments and
/// parsers in part 2.
enum Collector {
  /// The capability probe (03 §6.1). Emits one section per probe area on
  /// the slow sampler; the client requests it once after connect.
  probe(SamplerKind.slow, []),

  /// Fleet-row metrics: total cpu line, filtered meminfo, loadavg, netdev
  /// (03 §6.4, fast sampler).
  overview(SamplerKind.fast, []),

  /// Focused-server metrics: overview plus per-core cpu lines, btime,
  /// diskstats, pressure, uptime (03 §6.4, fast sampler).
  core(SamplerKind.fast, []),

  /// Mount usage and inodes from `df -PT -B1` and `df -Pi` (03 §6.4, §7.3,
  /// slow sampler under `timeout`).
  fs(SamplerKind.slow, []),

  /// Host identity: `/etc/os-release`, `uname`, `hostnamectl --json=short`
  /// (03 §6.4, slow sampler).
  identity(SamplerKind.slow, []);

  const Collector(this.sampler, this.argValidators);

  /// Which sampler's program contains this collector's fragment.
  final SamplerKind sampler;

  /// Positional validators for `hw_o` arguments; the request is refused
  /// when the argument count differs from this list's length or any
  /// validator rejects its argument. Part-1 collectors take no arguments:
  /// `hw_o <seq> <name>` is a bare on-demand re-read.
  final List<ArgValidator> argValidators;

  /// Wire name on `hw_t`/`hw_o` and in `S` section markers. Enum names all
  /// satisfy [collectorWireNamePattern].
  String get wireName => name;

  /// Looks up a collector by wire name; `null` when unknown.
  static Collector? byName(String name) {
    for (final c in values) {
      if (c.name == name) return c;
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
}

final _unitNamePattern = RegExp(
  '^[A-Za-z0-9:_.\\-]+(@[A-Za-z0-9:_.\\-]*)?\\.(service|socket|device|mount|'
  'automount|swap|target|path|timer|slice|scope)\$',
);

final _userNamePattern = RegExp(r'^[a-z_][a-z0-9_-]*[$]?$');

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

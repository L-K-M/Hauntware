/// The immutable result of the capability probe (03 §6.1). Every field is
/// nullable or holds an explicit enum value: unknown stays unknown, never
/// zero.
library;

import 'package:meta/meta.dart';

import '../cron/evaluate.dart' show ServerZone;
import '../hws/frames.dart' show SectionStatus;
import '../parse/parse_result.dart' show CounterWidth;

/// Which sudo implementation `sudo -V` reported (03 §6.1): sudo-rs is the
/// default on Ubuntu 25.10+ and its rejection texts differ (03 §6.6).
enum SudoKind {
  /// No `sudo` found (or the version line did not parse).
  none,

  /// Original sudo.
  sudo,

  /// sudo-rs.
  sudoRs,

  /// A sudo exists but its flavour could not be told.
  unknown,
}

/// One engine socket candidate from 03 §5.4, with the probe's answers.
@immutable
final class EngineSocket {
  const EngineSocket({
    required this.path,
    required this.exists,
    required this.writable,
  });

  /// Absolute socket path tested with `test -S`/`test -w`.
  final String path;

  /// `test -S` outcome; false when the path is absent or not a socket.
  final bool exists;

  /// `test -w` outcome (write permission implies connect permission).
  final bool writable;

  /// Rebuilds a socket from [toJson]'s output; see [HostProfile.fromJson].
  factory EngineSocket.fromJson(Map<String, Object?> json) {
    final r = _JsonReader(json, 'engine socket');
    return EngineSocket(
      path: r.required(r.string('path'), 'path'),
      exists: r.required(r.boolean('exists'), 'exists'),
      writable: r.required(r.boolean('writable'), 'writable'),
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'writable': writable,
  };
}

/// The system-wide `/proc` files of D50: inside a container each shows
/// the host's figures unless lxcfs serves the container's own there.
/// Namespaced files such as `/proc/net/dev` and `/proc/<pid>` are the
/// container's own and are deliberately not listed.
enum SystemWideProcFile {
  meminfo('/proc/meminfo', lxcfsShowsOwn: true),
  stat('/proc/stat', lxcfsShowsOwn: false),
  loadavg('/proc/loadavg', lxcfsShowsOwn: false),
  uptime('/proc/uptime', lxcfsShowsOwn: true),
  diskstats('/proc/diskstats', lxcfsShowsOwn: false),
  pressureCpu('/proc/pressure/cpu', lxcfsShowsOwn: true),
  pressureIo('/proc/pressure/io', lxcfsShowsOwn: false),
  pressureMemory('/proc/pressure/memory', lxcfsShowsOwn: true);

  const SystemWideProcFile(this.path, {required this._lxcfsShowsOwn});

  /// The absolute path, as `/proc/mounts` names a mount point.
  final String path;

  /// Whether a `fuse.lxcfs` mount over this file shows the container's
  /// own figures. False where lxcfs can serve the host's figures without
  /// a sign inside the container (D50):
  /// - `loadavg`, which lxcfs passes through unless it runs with `-l`;
  /// - `stat`, whose CPU times lxcfs takes from the cgroup v1 `cpuacct`
  ///   controller: lxcfs 5.0 and 6.0 find it only on a host with a
  ///   legacy or hybrid cgroup layout, and lxcfs 7, which supports
  ///   cgroup v2 only, never does. Without it, lxcfs copies the host's
  ///   lines for the CPUs in the container's cpuset and sums them into
  ///   the `cpu` line;
  /// - `diskstats` and `pressure/io`, for which lxcfs looks up a cgroup
  ///   controller named `blkio`, which cgroup v2 calls `io`. On cgroup
  ///   v1, `diskstats` also needs the `blkio.io_*_recursive` files that
  ///   went with the CFQ scheduler in Linux 5.0.
  ///
  /// Neither the `-l` flag, the lxcfs version nor, reliably, the host's
  /// cgroup layout shows inside the container.
  ///
  /// lxcfs also serves the host's `meminfo`, `pressure/cpu` and
  /// `pressure/memory` when it cannot use the memory or cpu controller,
  /// as on a kernel booted with `cgroup_disable=memory`. They stay
  /// trusted: that setup is rare and does not show reliably inside the
  /// container.
  ///
  /// `uptime`'s first field is the container's age either way. Its
  /// second, the idle time, is not the kernel's figure under lxcfs: the
  /// age minus the `cpuacct` busy time, or the age itself without one.
  final bool _lxcfsShowsOwn;
}

/// The probe's findings (03 §6.1), keyed by area; unknown stays null.
@immutable
final class HostProfile {
  HostProfile({
    this.kernelSys,
    this.kernelRelease,
    this.kernelArch,
    this.distroId,
    this.distroIdLike,
    this.distroVersionId,
    this.distroPrettyName,
    this.pid1Comm,
    this.systemdDir,
    this.systemctlVersionLine,
    this.systemdVersion,
    this.virtualization,
    this.container,
    List<String>? lxcfsMounts,
    this.uid,
    this.user,
    List<String>? groups,
    this.sudoVersionLine,
    this.sudoKind,
    this.sudoNonInteractive,
    this.doasPresent,
    this.doasNonInteractive,
    this.run0Present,
    this.run0NonInteractive,
    this.printfBuiltin,
    Map<String, String?>? tools,
    this.psi,
    this.cgroupV2,
    this.cUtf8,
    List<EngineSocket>? engineSockets,
    this.sshConnection,
    this.sessionParentPid,
    this.sessionParentComm,
    this.epochSeconds,
    this.zoneOffset,
    this.timezone,
    this.etcTimezone,
    this.localtimeTarget,
    this.ntpEnabled,
    this.ntpSynchronized,
    this.lingerEnabled,
    this.killUserProcesses,
    this.xdgRuntimeDir,
    Map<String, SectionStatus>? areaStatuses,
  }) : lxcfsMounts = lxcfsMounts == null
           ? null
           : List.unmodifiable(lxcfsMounts),
       groups = List.unmodifiable(groups ?? []),
       tools = Map.unmodifiable(tools ?? {}),
       engineSockets = List.unmodifiable(engineSockets ?? []),
       areaStatuses = Map.unmodifiable(areaStatuses ?? {});

  // kernel: `uname -s -r -m`, split.
  final String? kernelSys, kernelRelease, kernelArch;

  // distro: /etc/os-release fields.
  final String? distroId, distroIdLike, distroVersionId, distroPrettyName;

  // init: /proc/1/comm, /run/systemd/system, `systemctl --version`.
  final String? pid1Comm;

  /// Whether /run/systemd/system exists (systemd is running).
  final bool? systemdDir;

  /// First line of `systemctl --version`, verbatim.
  final String? systemctlVersionLine;

  /// Parsed major version (`systemd 252 (...)` -> 252).
  final int? systemdVersion;

  // virt: `systemd-detect-virt` and `-c`; 'none' or a name; null when the
  // tool is absent (unknown stays unknown).
  final String? virtualization, container;

  /// The `/proc` paths that are `fuse.lxcfs` mounts, in `/proc/mounts`
  /// order (D50): empty when there are none, null when unknown.
  final List<String>? lxcfsMounts;

  // identity: `id -u`, `id -un`, `id -nG`.
  final int? uid;
  final String? user;
  final List<String> groups;

  // elevation (03 §6.1, §8.3).
  final String? sudoVersionLine;
  final SudoKind? sudoKind;

  /// `sudo -n true` exit status: true when cached/non-interactive sudo
  /// works; null when sudo is absent.
  final bool? sudoNonInteractive;
  final bool? doasPresent;

  /// `doas -n true` exit status; null without doas.
  final bool? doasNonInteractive;
  final bool? run0Present;

  /// `run0 --no-ask-password true` exit status (03 §8.3 rung 6): true when
  /// polkit lets run0 elevate without asking; null without run0 or from a
  /// probe before collector-set version 8.
  final bool? run0NonInteractive;

  /// `command -V printf` outcome (03 §8.3 needs to know whether the
  /// password read uses a builtin).
  final bool? printfBuiltin;

  /// Tool name to resolved path; the value is null when the tool is
  /// absent (03 §6.1 tools list).
  final Map<String, String?> tools;

  // kernel features.
  final bool? psi, cgroupV2;

  /// `locale -a` contains C.UTF-8 (03 §6.1).
  final bool? cUtf8;

  /// Engine socket candidates of 03 §5.4, in probe order.
  final List<EngineSocket> engineSockets;

  // session (protected targets).
  final String? sshConnection;
  final int? sessionParentPid;
  final String? sessionParentComm;

  // clock (03 §6.1): epoch + zone read under `(unset TZ; ...)`.
  final int? epochSeconds;
  final String? zoneOffset;
  final String? timezone, etcTimezone, localtimeTarget;

  /// timedatectl's `NTP` and `NTPSynchronized` (SYS-02): whether a time
  /// sync service is enabled, and whether the kernel clock is in sync;
  /// null where timedatectl did not say, as without systemd.
  final bool? ntpEnabled, ntpSynchronized;

  // detached-operation support (03 §6.1).
  final bool? lingerEnabled;
  final String? killUserProcesses;
  final String? xdgRuntimeDir;

  /// Per-area section status (`probe_<area>` name minus the `probe_`
  /// prefix), so a panel can say why a fact is unknown.
  final Map<String, SectionStatus> areaStatuses;

  /// Whether the host has `timeout` for the slow sampler's guard.
  bool? get timeoutPresent => toolPresent('timeout');

  /// Whether the probe found [tool]: null when the probe did not report
  /// it (the tools area failed, or a profile from before the tool joined
  /// the list), so unknown stays unknown.
  bool? toolPresent(String tool) =>
      tools.containsKey(tool) ? tools[tool] != null : null;

  /// Whether [file] may show the container host's figures rather than
  /// this system's own (D50, SYS-04), so its values must show as unknown
  /// with that reason. False when lxcfs serves the container's own
  /// figures there, which it does not do reliably for `stat`, `loadavg`,
  /// `diskstats` and `pressure/io`, or when `systemd-detect-virt -c`
  /// found no container; true inside a container otherwise; null when
  /// neither is known, as on a host without `systemd-detect-virt` and
  /// without lxcfs mounts. An lxcfs mount over any `/proc` path tells
  /// that this is a container, even when `systemd-detect-virt -c`
  /// answered `none`; a mount over a directory such as `/proc/pressure`
  /// covers the files below it.
  bool? showsHostFigures(SystemWideProcFile file) {
    final mounts = lxcfsMounts;
    if (mounts != null && mounts.isNotEmpty) {
      final served = mounts.any(
        (m) => file.path == m || file.path.startsWith('$m/'),
      );
      return !(served && file._lxcfsShowsOwn);
    }

    return inContainer;
  }

  /// Whether this system is a container (SYS-04, D50): true with an lxcfs
  /// mount over any `/proc` path, even when `systemd-detect-virt -c`
  /// answered `none`; otherwise that answer; null when neither is known.
  bool? get inContainer {
    final mounts = lxcfsMounts;
    if (mounts != null && mounts.isNotEmpty) return true;

    final c = container;
    return c == null ? null : c != 'none';
  }

  /// The width of this kernel's `/proc` counters (CN-04): 32 bits when
  /// `uname -m` names a 32-bit kernel, else 64, which `ParseContext` also
  /// assumes when the architecture is unknown.
  ///
  /// `uname -m` reports the process personality: a 64-bit x86 kernel
  /// under a 32-bit personality, as in an LXC container with
  /// `lxc.arch = i686`, reports `i686` and counts as 32 bits here, so a
  /// counter reset there reads as a wrap. `/proc/sys/kernel/arch` (Linux
  /// 6.1 and later) keeps the kernel's own name; the probe does not read
  /// it yet.
  CounterWidth get counterWidth {
    final arch = kernelArch;
    if (arch != null && _kernel32Pattern.hasMatch(arch)) {
      return CounterWidth.bits32;
    }
    return CounterWidth.bits64;
  }

  /// The server's time zone for cron next runs (03 §7.7, JOB-02): the
  /// probe's fixed `zoneOffset` plus the best IANA name it found, or null
  /// when the offset is absent or malformed. `offsetAt` stays null; the
  /// engine supplies the rule lookup and keeps the zone to itself (D52).
  ServerZone? get serverZone {
    final offset = _parseZoneOffset(zoneOffset);
    if (offset == null) return null;
    return ServerZone(offset: offset, ianaName: _zoneName());
  }

  /// `timedatectl`'s answer first; then the `/etc/localtime` link target,
  /// which libc reads when `TZ` is unset, as for cron (6.2); then
  /// `/etc/timezone`, which can be stale.
  String? _zoneName() {
    for (final candidate in [
      timezone,
      _zoneFromLocaltime(localtimeTarget),
      etcTimezone,
    ]) {
      if (candidate != null && _zoneNamePattern.hasMatch(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /// Rebuilds a profile from [toJson]'s output, for the device cache
  /// (6.1). Unknown keys are ignored and absent keys stay unknown, so a
  /// profile cached by another collector-set version still reads; a value
  /// of the wrong type throws a [FormatException] naming the key, and the
  /// caller probes again.
  factory HostProfile.fromJson(Map<String, Object?> json) {
    final r = _JsonReader(json, 'host profile');
    return HostProfile(
      kernelSys: r.string('kernelSys'),
      kernelRelease: r.string('kernelRelease'),
      kernelArch: r.string('kernelArch'),
      distroId: r.string('distroId'),
      distroIdLike: r.string('distroIdLike'),
      distroVersionId: r.string('distroVersionId'),
      distroPrettyName: r.string('distroPrettyName'),
      pid1Comm: r.string('pid1Comm'),
      systemdDir: r.boolean('systemdDir'),
      systemctlVersionLine: r.string('systemctlVersionLine'),
      systemdVersion: r.integer('systemdVersion'),
      virtualization: r.string('virtualization'),
      container: r.string('container'),
      lxcfsMounts: r.strings('lxcfsMounts'),
      uid: r.integer('uid'),
      user: r.string('user'),
      groups: r.strings('groups'),
      sudoVersionLine: r.string('sudoVersionLine'),
      sudoKind: r.enumValue('sudoKind', SudoKind.values),
      sudoNonInteractive: r.boolean('sudoNonInteractive'),
      doasPresent: r.boolean('doasPresent'),
      doasNonInteractive: r.boolean('doasNonInteractive'),
      run0Present: r.boolean('run0Present'),
      run0NonInteractive: r.boolean('run0NonInteractive'),
      printfBuiltin: r.boolean('printfBuiltin'),
      tools: r
          .map('tools')
          ?.map((k, v) => MapEntry(k, v is String? ? v : r.fail('tools.$k'))),
      psi: r.boolean('psi'),
      cgroupV2: r.boolean('cgroupV2'),
      cUtf8: r.boolean('cUtf8'),
      engineSockets: [
        for (final (i, s) in (r.list('engineSockets') ?? const []).indexed)
          s is Map<String, Object?>
              ? EngineSocket.fromJson(s)
              : r.fail('engineSockets[$i]'),
      ],
      sshConnection: r.string('sshConnection'),
      sessionParentPid: r.integer('sessionParentPid'),
      sessionParentComm: r.string('sessionParentComm'),
      epochSeconds: r.integer('epochSeconds'),
      zoneOffset: r.string('zoneOffset'),
      timezone: r.string('timezone'),
      etcTimezone: r.string('etcTimezone'),
      localtimeTarget: r.string('localtimeTarget'),
      ntpEnabled: r.boolean('ntpEnabled'),
      ntpSynchronized: r.boolean('ntpSynchronized'),
      lingerEnabled: r.boolean('lingerEnabled'),
      killUserProcesses: r.string('killUserProcesses'),
      xdgRuntimeDir: r.string('xdgRuntimeDir'),
      areaStatuses: r
          .map('areaStatuses')
          ?.map(
            (k, v) => MapEntry(
              k,
              _byName(SectionStatus.values, v) ?? r.fail('areaStatuses.$k'),
            ),
          ),
    );
  }

  Map<String, Object?> toJson() => {
    'kernelSys': kernelSys,
    'kernelRelease': kernelRelease,
    'kernelArch': kernelArch,
    'distroId': distroId,
    'distroIdLike': distroIdLike,
    'distroVersionId': distroVersionId,
    'distroPrettyName': distroPrettyName,
    'pid1Comm': pid1Comm,
    'systemdDir': systemdDir,
    'systemctlVersionLine': systemctlVersionLine,
    'systemdVersion': systemdVersion,
    'virtualization': virtualization,
    'container': container,
    'lxcfsMounts': lxcfsMounts,
    'uid': uid,
    'user': user,
    'groups': groups,
    'sudoVersionLine': sudoVersionLine,
    'sudoKind': sudoKind?.name,
    'sudoNonInteractive': sudoNonInteractive,
    'doasPresent': doasPresent,
    'doasNonInteractive': doasNonInteractive,
    'run0Present': run0Present,
    'run0NonInteractive': run0NonInteractive,
    'printfBuiltin': printfBuiltin,
    'tools': tools,
    'psi': psi,
    'cgroupV2': cgroupV2,
    'cUtf8': cUtf8,
    'engineSockets': engineSockets.map((s) => s.toJson()).toList(),
    'sshConnection': sshConnection,
    'sessionParentPid': sessionParentPid,
    'sessionParentComm': sessionParentComm,
    'epochSeconds': epochSeconds,
    'zoneOffset': zoneOffset,
    'timezone': timezone,
    'etcTimezone': etcTimezone,
    'localtimeTarget': localtimeTarget,
    'ntpEnabled': ntpEnabled,
    'ntpSynchronized': ntpSynchronized,
    'lingerEnabled': lingerEnabled,
    'killUserProcesses': killUserProcesses,
    'xdgRuntimeDir': xdgRuntimeDir,
    'areaStatuses': areaStatuses.map((k, v) => MapEntry(k, v.name)),
  };
}

/// `uname -m` of 32-bit Linux kernels: x86 (`i386` to `i686`), ARM up to
/// ARMv7 (`armv7l`; `armv8l` is the 32-bit personality of a 64-bit
/// kernel), and the 32-bit MIPS, PowerPC, s390, SPARC, RISC-V, PA-RISC and
/// m68k names (64-bit kernels report `mips64`, `ppc64`, `s390x` and so
/// on).
final _kernel32Pattern = RegExp(
  r'^(i[3-6]86|armv[4-7][a-z]*|mips|ppc|s390|sparc|riscv32|parisc|m68k)$',
);

/// `date +%z` output: a sign, two hour and two minute digits.
final _zoneOffsetPattern = RegExp(r'^([+-])(\d{2})(\d{2})$');

/// The offset in [text], or null unless it lies within the offsets in
/// use, `-1200` to `+1400`.
Duration? _parseZoneOffset(String? text) {
  final m = text == null ? null : _zoneOffsetPattern.firstMatch(text);
  if (m == null) return null;

  final minutes = int.parse(m[3]!);
  if (minutes > 59) return null;

  final magnitude = Duration(hours: int.parse(m[2]!), minutes: minutes);
  final offset = m[1] == '-' ? -magnitude : magnitude;
  if (offset < const Duration(hours: -12) ||
      offset > const Duration(hours: 14)) {
    return null;
  }
  return offset;
}

/// IANA zone names: slash-separated words, as in `Europe/Berlin`,
/// `America/Port-au-Prince` or `Etc/GMT+5`.
final _zoneNamePattern = RegExp(r'^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$');

/// The zone name in a `/etc/localtime` link target such as
/// `../usr/share/zoneinfo/Europe/Berlin`: the part after `zoneinfo/`,
/// without tzdata's `posix/` or `right/` (leap-second) subtree prefix.
/// Null for any other target.
String? _zoneFromLocaltime(String? target) {
  if (target == null) return null;

  const marker = 'zoneinfo/';
  final at = target.lastIndexOf(marker);
  if (at < 0) return null;

  final name = target.substring(at + marker.length);
  for (final subtree in const ['posix/', 'right/']) {
    if (name.startsWith(subtree)) return name.substring(subtree.length);
  }
  return name;
}

E? _byName<E extends Enum>(List<E> values, Object? name) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

/// Typed reads from a decoded JSON object for the `fromJson` factories:
/// an absent or null key is null, a value of another type a
/// [FormatException] naming the key.
final class _JsonReader {
  _JsonReader(this._json, this._what);

  final Map<String, Object?> _json;
  final String _what;

  Never fail(String key) =>
      throw FormatException('$_what: unusable value at "$key"');

  T required<T>(T? value, String key) => value ?? fail(key);

  T? _typed<T>(String key) => switch (_json[key]) {
    null => null,
    final T v => v,
    _ => fail(key),
  };

  String? string(String key) => _typed<String>(key);
  bool? boolean(String key) => _typed<bool>(key);
  int? integer(String key) => _typed<int>(key);
  List<Object?>? list(String key) => _typed<List<Object?>>(key);
  Map<String, Object?>? map(String key) => _typed<Map<String, Object?>>(key);

  List<String>? strings(String key) => switch (list(key)) {
    null => null,
    final l => [
      for (final (i, e) in l.indexed) e is String ? e : fail('$key[$i]'),
    ],
  };

  E? enumValue<E extends Enum>(String key, List<E> values) {
    final name = string(key);
    if (name == null) return null;
    return _byName(values, name) ?? fail(key);
  }
}

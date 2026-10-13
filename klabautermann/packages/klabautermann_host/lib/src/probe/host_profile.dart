/// The immutable result of the capability probe (03 §6.1). Every field is
/// nullable or holds an explicit enum value: unknown stays unknown, never
/// zero.
library;

import 'package:meta/meta.dart';

import '../hws/frames.dart' show SectionStatus;

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

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'writable': writable,
  };
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
    this.uid,
    this.user,
    List<String>? groups,
    this.sudoVersionLine,
    this.sudoKind,
    this.sudoNonInteractive,
    this.doasPresent,
    this.doasNonInteractive,
    this.run0Present,
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
    this.lingerEnabled,
    this.killUserProcesses,
    this.xdgRuntimeDir,
    Map<String, SectionStatus>? areaStatuses,
  }) : groups = List.unmodifiable(groups ?? []),
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

  // detached-operation support (03 §6.1).
  final bool? lingerEnabled;
  final String? killUserProcesses;
  final String? xdgRuntimeDir;

  /// Per-area section status (`probe_<area>` name minus the `probe_`
  /// prefix), so a panel can say why a fact is unknown.
  final Map<String, SectionStatus> areaStatuses;

  /// Whether the host has `timeout` for the slow sampler's guard.
  bool? get timeoutPresent =>
      tools.containsKey('timeout') ? tools['timeout'] != null : null;

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
    'uid': uid,
    'user': user,
    'groups': groups,
    'sudoVersionLine': sudoVersionLine,
    'sudoKind': sudoKind?.name,
    'sudoNonInteractive': sudoNonInteractive,
    'doasPresent': doasPresent,
    'doasNonInteractive': doasNonInteractive,
    'run0Present': run0Present,
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
    'lingerEnabled': lingerEnabled,
    'killUserProcesses': killUserProcesses,
    'xdgRuntimeDir': xdgRuntimeDir,
    'areaStatuses': areaStatuses.map((k, v) => MapEntry(k, v.name)),
  };
}

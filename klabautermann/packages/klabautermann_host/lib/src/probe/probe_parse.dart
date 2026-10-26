/// Parses the capability probe's per-area sections into a [HostProfile]
/// (03 §6.1). Sections are the `probe_<area>` frames the `probe` collector
/// emits; each is a small `key=value` or raw-text payload.
library;

import 'dart:convert';

import '../hws/frames.dart' show HwsSection, SectionStatus;
import '../hws/program.dart' show kTimeoutAbsentMarker;
import '../parse/identity.dart' show parseOsReleaseLines;
import '../parse/parse_result.dart';
import 'host_profile.dart';

/// The section-name prefix the probe fragment emits (03 §6.1).
const kProbeSectionPrefix = 'probe_';

/// One decoded probe section: [name] without the `probe_` prefix,
/// [status] and the UTF-8-decoded [payload] (malformed bytes tolerated).
final class ProbeSection {
  ProbeSection(this.name, this.status, this.payload);

  /// Builds a section from a frame-parser event; returns null for names
  /// outside the `probe_` vocabulary. `hw_timeout=absent` lines are
  /// stripped here: `psec` prepends them when the host lacks `timeout`
  /// (03 §6.3), and the `tools` area already reports that fact.
  static ProbeSection? fromEvent(HwsSection s) {
    if (!s.collector.startsWith(kProbeSectionPrefix)) return null;
    final text = utf8.decode(s.payload, allowMalformed: true);
    final payload = text
        .split('\n')
        .where((l) => l != kTimeoutAbsentMarker)
        .join('\n');
    return ProbeSection(
      s.collector.substring(kProbeSectionPrefix.length),
      s.status,
      payload,
    );
  }

  final String name;
  final SectionStatus status;
  final String payload;
}

/// Parses a probe reply (03 §6.1, §6.5). Sections with a non-ok status
/// keep their fields unknown and land in [HostProfile.areaStatuses] with
/// a warning; the parser never throws.
ParseResult<HostProfile> parseProbe(
  List<ProbeSection> sections,
  ParseContext ctx,
) {
  final warnings = <String>[];
  final areaStatuses = <String, SectionStatus>{};
  final p = _ProfileBuilder();
  for (final s in sections) {
    areaStatuses[s.name] = s.status;
    if (s.status != SectionStatus.ok) {
      warnings.add('probe area ${s.name} reported ${s.status.name}');
      continue;
    }
    switch (s.name) {
      case 'kernel':
        p.kernel(s.payload, warnings);
      case 'distro':
        p.distro(s.payload, warnings);
      case 'init':
        p.init(s.payload, warnings);
      case 'virt':
        p.virt(s.payload, warnings);
      case 'lxcfs':
        p.lxcfs(s.payload, warnings);
      case 'identity':
        p.identity(s.payload, warnings);
      case 'elev':
        p.elev(s.payload, warnings);
      case 'tools':
        p.toolList(s.payload, warnings);
      case 'kfeat':
        p.kfeat(s.payload, warnings);
      case 'locale':
        p.locale(s.payload, warnings);
      case 'sockets':
        p.sockets(s.payload, warnings);
      case 'session':
        p.session(s.payload, warnings);
      case 'clock':
        p.clock(s.payload, warnings);
      case 'linger':
        p.linger(s.payload, warnings);
      default:
        warnings.add('unknown probe area ${s.name} ignored');
    }
  }
  return ParseResult(p.build(areaStatuses), warnings);
}

/// Accumulates HostProfile fields across areas.
final class _ProfileBuilder {
  String? kernelSys, kernelRelease, kernelArch;
  String? distroId, distroIdLike, distroVersionId, distroPrettyName;
  String? pid1Comm, systemctlVersionLine;
  bool? systemdDir;
  int? systemdVersion;
  String? virtualization, container;
  List<String>? lxcfsMounts;
  int? uid;
  String? user;
  List<String>? groups;
  String? sudoVersionLine;
  SudoKind? sudoKind;
  bool? sudoNonInteractive,
      doasPresent,
      doasNonInteractive,
      run0Present,
      run0NonInteractive,
      printfBuiltin;
  Map<String, String?> tools = {};
  bool? psi, cgroupV2, cUtf8;
  List<EngineSocket> engineSockets = [];
  String? sshConnection, sessionParentComm;
  int? sessionParentPid;
  int? epochSeconds;
  String? zoneOffset, timezone, etcTimezone, localtimeTarget;
  bool? ntpEnabled, ntpSynchronized;
  bool? lingerEnabled;
  String? killUserProcesses, xdgRuntimeDir;

  void kernel(String payload, List<String> w) {
    final line = payload.trim();
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length >= 3) {
      kernelSys = parts[0];
      kernelRelease = parts[1];
      kernelArch = parts[2];
    } else {
      w.add('probe kernel: malformed uname output');
    }
  }

  void distro(String payload, List<String> w) {
    final r = parseOsReleaseLines(payload.split('\n'), w);
    distroId = r.id;
    distroIdLike = r.idLike;
    distroVersionId = r.versionId;
    distroPrettyName = r.prettyName;
  }

  void init(String payload, List<String> w) {
    final kv = _kv(payload);
    pid1Comm = _emptyNull(kv['pid1_comm']);
    systemdDir = _yesNo(kv['systemd_dir']);
    systemctlVersionLine = _emptyNull(kv['systemctl_version']);
    final v = systemctlVersionLine;
    if (v != null) {
      final m = RegExp(r'^systemd\s+(\d+)').firstMatch(v);
      if (m != null) {
        systemdVersion = int.tryParse(m[1]!);
      } else {
        w.add('probe init: unparsed systemctl version "$v"');
      }
    }
  }

  void virt(String payload, List<String> w) {
    final kv = _kv(payload);
    virtualization = _detected(kv['virt_rc'], kv['virt'], 'virt', w);
    container = _detected(kv['container_rc'], kv['container'], 'container', w);
  }

  /// One `systemd-detect-virt` answer: exit 0 with the technology's
  /// name, or 'none', which is an answer, not an unknown. Any other
  /// output (an error message) leaves it unknown.
  String? _detected(String? rc, String? out, String what, List<String> w) {
    final name = _emptyNull(out);
    if (name == 'none' || (rc == '0' && name != null)) return name;
    if (name != null) w.add('probe virt: unparsed $what answer "$name"');
    return null;
  }

  void lxcfs(String payload, List<String> w) {
    final mounts = _kv(payload)['mounts'];
    if (mounts == null) {
      w.add('probe lxcfs: no mounts line');
      return;
    }
    final out = <String>[];
    for (final m in mounts.split(' ')) {
      if (m.startsWith('/proc/')) {
        out.add(m);
      } else if (m.isNotEmpty) {
        w.add('probe lxcfs: ignored mount point "$m"');
      }
    }
    lxcfsMounts = out;
  }

  void identity(String payload, List<String> w) {
    final kv = _kv(payload);
    uid = int.tryParse(kv['uid'] ?? '');
    user = _emptyNull(kv['user']);
    final g = kv['groups'];
    groups = g == null || g.trim().isEmpty
        ? const []
        : g.trim().split(RegExp(r'\s+'));
  }

  void elev(String payload, List<String> w) {
    final kv = _kv(payload);
    sudoVersionLine = _emptyNull(kv['sudo_version']);
    sudoKind = sudoVersionLine != null
        ? _sudoKind(sudoVersionLine)
        : (kv.containsKey('sudo_version') ? SudoKind.none : null);
    sudoNonInteractive = _rcZero(kv['sudo_noninteractive']);
    doasPresent = _present(kv['doas']);
    doasNonInteractive = _rcZero(kv['doas_noninteractive']);
    run0Present = _present(kv['run0']);
    run0NonInteractive = _rcZero(kv['run0_noninteractive']);
    printfBuiltin = switch (kv['printf']) {
      'builtin' => true,
      'external' => false,
      _ => null,
    };
  }

  void toolList(String payload, List<String> w) {
    final kv = _kv(payload);
    for (final e in kv.entries) {
      tools[e.key] = _emptyNull(e.value);
    }
  }

  void kfeat(String payload, List<String> w) {
    final kv = _kv(payload);
    psi = _yesNo(kv['psi']);
    cgroupV2 = _yesNo(kv['cgroup_v2']);
  }

  void locale(String payload, List<String> w) {
    cUtf8 = _yesNo(_kv(payload)['c_utf8']);
  }

  void sockets(String payload, List<String> w) {
    final out = <EngineSocket>[];
    for (final line in payload.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length != 3 || !parts[0].startsWith('/')) {
        w.add('probe sockets: malformed row "$t"');
        continue;
      }
      out.add(
        EngineSocket(
          path: parts[0],
          exists: parts[1] == 'yes',
          writable: parts[2] == 'yes',
        ),
      );
    }
    engineSockets = out;
  }

  void session(String payload, List<String> w) {
    final kv = _kv(payload);
    sshConnection = _emptyNull(kv['ssh_connection']);
    sessionParentPid = int.tryParse(kv['ppid'] ?? '');
    sessionParentComm = _emptyNull(kv['ppid_comm']);
  }

  void clock(String payload, List<String> w) {
    final kv = _kv(payload);
    epochSeconds = int.tryParse(kv['epoch'] ?? '');
    zoneOffset = _emptyNull(kv['offset']);
    timezone = _emptyNull(kv['Timezone']);
    etcTimezone = _emptyNull(kv['etc_timezone']);
    localtimeTarget = _emptyNull(kv['localtime']);
    ntpEnabled = _yesNo(kv['NTP']);
    ntpSynchronized = _yesNo(kv['NTPSynchronized']);
    if (kv['timedatectl_error'] == 'yes' && timezone == null) {
      w.add('probe clock: timedatectl failed');
    }
  }

  void linger(String payload, List<String> w) {
    final kv = _kv(payload);
    xdgRuntimeDir = _emptyNull(kv['xdg_runtime_dir']);
    lingerEnabled = _yesNo(kv['Linger']);
    killUserProcesses = _emptyNull(kv['KillUserProcesses']);
  }

  HostProfile build(Map<String, SectionStatus> areaStatuses) => HostProfile(
    kernelSys: kernelSys,
    kernelRelease: kernelRelease,
    kernelArch: kernelArch,
    distroId: distroId,
    distroIdLike: distroIdLike,
    distroVersionId: distroVersionId,
    distroPrettyName: distroPrettyName,
    pid1Comm: pid1Comm,
    systemdDir: systemdDir,
    systemctlVersionLine: systemctlVersionLine,
    systemdVersion: systemdVersion,
    virtualization: virtualization,
    container: container,
    lxcfsMounts: lxcfsMounts,
    uid: uid,
    user: user,
    groups: groups,
    sudoVersionLine: sudoVersionLine,
    sudoKind: sudoKind,
    sudoNonInteractive: sudoNonInteractive,
    doasPresent: doasPresent,
    doasNonInteractive: doasNonInteractive,
    run0Present: run0Present,
    run0NonInteractive: run0NonInteractive,
    printfBuiltin: printfBuiltin,
    tools: tools,
    psi: psi,
    cgroupV2: cgroupV2,
    cUtf8: cUtf8,
    engineSockets: engineSockets,
    sshConnection: sshConnection,
    sessionParentPid: sessionParentPid,
    sessionParentComm: sessionParentComm,
    epochSeconds: epochSeconds,
    zoneOffset: zoneOffset,
    timezone: timezone,
    etcTimezone: etcTimezone,
    localtimeTarget: localtimeTarget,
    ntpEnabled: ntpEnabled,
    ntpSynchronized: ntpSynchronized,
    lingerEnabled: lingerEnabled,
    killUserProcesses: killUserProcesses,
    xdgRuntimeDir: xdgRuntimeDir,
    areaStatuses: areaStatuses,
  );
}

/// `key=value` lines to a map; malformed lines are skipped.
Map<String, String> _kv(String payload) {
  final out = <String, String>{};
  for (final line in payload.split('\n')) {
    final t = line.trimRight();
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    out[t.substring(0, eq)] = t.substring(eq + 1);
  }
  return out;
}

String? _emptyNull(String? v) => v == null || v.isEmpty ? null : v;
bool? _yesNo(String? v) => switch (v) {
  'yes' => true,
  'no' => false,
  _ => null,
};
bool? _rcZero(String? v) => switch (v) {
  '0' => true,
  '' || null => null,
  _ => false,
};
bool? _present(String? v) => switch (v) {
  'present' => true,
  'absent' => false,
  _ => null,
};

SudoKind? _sudoKind(String? versionLine) {
  if (versionLine == null) return null;
  final v = versionLine.toLowerCase();
  if (v.contains('sudo-rs') || v.contains('sudo_rs')) return SudoKind.sudoRs;
  if (v.startsWith('sudo version') || v.contains('sudo')) {
    return SudoKind.sudo;
  }
  return SudoKind.unknown;
}

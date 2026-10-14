/// Panel capability declarations (03 §6.1, §10.4): each host panel names
/// what it needs, and a panel that cannot work is hidden with the
/// blocking capability and, where one exists, the access check's fix.
/// Docker panels follow the transport ladder and arrive with M3.
library;

import 'package:meta/meta.dart';

import '../probe/host_profile.dart';
import 'access_check.dart';

/// Something a panel can need.
enum Capability {
  /// systemd is PID 1.
  systemd,

  /// The probe found `journalctl`.
  journalctl,

  /// The whole journal is readable (the access check's journal row).
  journalAccess,

  /// `dmesg` can read the kernel ring, LOG-03's fallback. Missing when
  /// the probe found no `dmesg`, otherwise unknown: reading needs
  /// CAP_SYSLOG under `kernel.dmesg_restrict=1` (the Debian and Ubuntu
  /// default; containers drop it even for root), and 03 §7.6's
  /// `dmesg --json` is absent from BusyBox and util-linux 2.32 (RHEL 8).
  /// LOG-03 probes both before this can be ok.
  dmesg,

  /// The probe found `tail` (LOG-22).
  tail,

  /// The probe found `crontab`.
  crontab,
}

/// The M2 host panels (04 §13).
enum HostPanel {
  overview,
  processes,
  services,
  unitLogs,
  journal,
  kernelLog,
  fileTail,
  jobs,
  identity,
}

/// Each panel's alternatives, preferred first; a panel works when every
/// capability of one alternative is ok. An empty alternative needs only
/// the samplers' `/proc` and `/sys` reads. Without journal access the
/// journal and unit logs still work and show the LOG-04 notice
/// ([AccessReport.journalLimited]); the kernel log has nothing to show,
/// since kernel entries are never the user's own.
const kPanelNeeds = <HostPanel, List<List<Capability>>>{
  HostPanel.overview: [[]],
  HostPanel.processes: [[]],
  HostPanel.services: [
    [Capability.systemd],
  ],
  HostPanel.unitLogs: [
    [Capability.systemd, Capability.journalctl],
  ],
  HostPanel.journal: [
    [Capability.journalctl],
  ],
  HostPanel.kernelLog: [
    [Capability.journalctl, Capability.journalAccess],
    [Capability.dmesg],
  ],
  HostPanel.fileTail: [
    [Capability.tail],
  ],
  HostPanel.jobs: [
    [Capability.crontab],
    [Capability.systemd],
  ],
  HostPanel.identity: [[]],
};

/// Whether a panel can work on one host.
@immutable
final class PanelAvailability {
  PanelAvailability(
    this.panel,
    this.status, {
    List<Capability> route = const [],
    List<Capability> blocking = const [],
    this.fix,
  }) : route = List.unmodifiable(route),
       blocking = List.unmodifiable(blocking);

  final HostPanel panel;
  final AccessStatus status;

  /// The alternative that works, when [status] is ok: for the kernel log
  /// it says whether to read `journalctl -k -b` or fall back to `dmesg`
  /// (once LOG-03 probes it, [Capability.dmesg]).
  final List<Capability> route;

  /// What keeps the panel from working: the unknown capabilities of the
  /// first undecided alternative, or the missing ones of the preferred
  /// alternative. Empty when [status] is ok.
  final List<Capability> blocking;

  /// The access check's fix for a blocking capability, when one exists.
  final AccessFix? fix;
}

/// The status of [capability] on the host [profile] describes.
AccessStatus _capabilityStatus(
  Capability capability,
  HostProfile profile,
  AccessReport access,
) {
  final bool? present;
  switch (capability) {
    case Capability.journalAccess:
      return access.row(AccessItem.journal).status;
    case Capability.dmesg:
      return profile.toolPresent('dmesg') == false
          ? AccessStatus.missing
          : AccessStatus.unknown;
    case Capability.systemd:
      present = profile.systemdDir;
    // Tool capabilities are named after the probed tool.
    case Capability.journalctl || Capability.tail || Capability.crontab:
      present = profile.toolPresent(capability.name);
  }

  return switch (present) {
    true => AccessStatus.ok,
    false => AccessStatus.missing,
    null => AccessStatus.unknown,
  };
}

/// Evaluates [panel] against its declaration: ok when one alternative is
/// fully met, unknown while an alternative has no known lack, missing
/// only when every alternative lacks something the probe answered.
PanelAvailability evaluatePanel(
  HostPanel panel,
  HostProfile profile,
  AccessReport access,
) {
  List<Capability>? undecided;
  List<Capability>? lacking;
  for (final alternative in kPanelNeeds[panel]!) {
    final statuses = {
      for (final c in alternative) c: _capabilityStatus(c, profile, access),
    };
    List<Capability> having(AccessStatus s) => [
      for (final c in alternative)
        if (statuses[c] == s) c,
    ];
    final missing = having(AccessStatus.missing);
    final unknown = having(AccessStatus.unknown);
    if (missing.isEmpty && unknown.isEmpty) {
      return PanelAvailability(panel, AccessStatus.ok, route: alternative);
    }
    if (missing.isEmpty) {
      undecided ??= unknown;
    } else {
      lacking ??= missing;
    }
  }

  if (undecided != null) {
    return PanelAvailability(panel, AccessStatus.unknown, blocking: undecided);
  }
  final blocking = lacking!;
  return PanelAvailability(
    panel,
    AccessStatus.missing,
    blocking: blocking,
    fix: blocking.contains(Capability.journalAccess)
        ? access.row(AccessItem.journal).fix
        : null,
  );
}

/// Every [HostPanel], in enum order.
List<PanelAvailability> evaluatePanels(
  HostProfile profile,
  AccessReport access,
) => [for (final p in HostPanel.values) evaluatePanel(p, profile, access)];

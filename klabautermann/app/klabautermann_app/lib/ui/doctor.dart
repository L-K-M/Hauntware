import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/docker_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'certificates.dart' show kTlsExpirySoon;
import 'charts/charts.dart' show ChartSeverity;
import 'docker/images_view.dart' show imageTagsOf;
import 'overview_panel.dart' show DiskMeasure, diskAlarms;
import 'system_view.dart' show clockSkewText, kClockInStep;
import 'threshold_scope.dart' show kDefaultThresholds;

/// TRI-01's checks, in the order the checklist lists them.
enum DoctorCheckKind {
  diskSpace,
  inodes,
  failedUnits,
  securityUpdates,
  rebootRequired,
  timeSync,
  certificates,
  dockerDiskUse,
  danglingImages,
}

/// What one check found.
enum DoctorVerdict {
  /// Needs action now.
  problem,

  /// Worth a look.
  warning,

  /// Its reading failed or has not arrived.
  unknown,

  /// Its on-demand read is under way.
  checking,

  /// Nothing to check: no endpoint is listed for the server.
  notSetUp,

  ok,
}

/// One TRI-01 finding with what it names: a [count], a size in [bytes],
/// the mounts, units, packages or endpoints concerned ([names]), or the
/// clock's [skew].
@immutable
final class DoctorCheck {
  const DoctorCheck(
    this.kind,
    this.verdict, {
    this.count,
    this.bytes,
    this.names = const [],
    this.skew,
  });

  final DoctorCheckKind kind;
  final DoctorVerdict verdict;
  final int? count;
  final int? bytes;
  final List<String> names;
  final Duration? skew;

  @override
  bool operator ==(Object other) =>
      other is DoctorCheck &&
      other.kind == kind &&
      other.verdict == verdict &&
      other.count == count &&
      other.bytes == bytes &&
      listEquals(other.names, names) &&
      other.skew == skew;

  @override
  int get hashCode =>
      Object.hash(kind, verdict, count, bytes, Object.hashAll(names), skew);
}

/// Docker data that `docker system prune` would free from which it is
/// worth saying [E]: below a gibibyte a prune frees little on any disk.
const int _reclaimableBytes = 1 << 30;

/// What the checks read: the server's held readings, and the answers of
/// the reads the doctor runs on demand.
@immutable
final class DoctorInputs {
  const DoctorInputs({
    required this.now,
    this.fs,
    this.fsFailed = false,
    this.failedUnits,
    this.profile,
    this.skew,
    this.packages,
    this.packagesReading = false,
    this.endpoints = const [],
    this.tlsChecks,
    this.tlsChecking = false,
    this.docker = false,
    this.diskUse,
    this.images,
  });

  /// The clock certificate expiry counts from.
  final DateTime now;

  /// The last `df` listing; [fsFailed] when the latest one failed, which
  /// leaves every mount's use unknown.
  final FsSnapshot? fs;
  final bool fsFailed;

  final List<SystemdUnit>? failedUnits;
  final HostProfile? profile;

  /// The server's clock less this device's.
  final Duration? skew;

  /// The package check; null while [packagesReading].
  final PackagesReport? packages;
  final bool packagesReading;

  /// The endpoints listed for the server, and their checks; null while
  /// [tlsChecking] or when the engine stopped before answering.
  final List<TlsEndpoint> endpoints;
  final List<TlsEndpointCheck>? tlsChecks;
  final bool tlsChecking;

  /// Whether the server shows a Docker endpoint; without one the Docker
  /// checks are left out.
  final bool docker;
  final DockerDiskUse? diskUse;
  final List<ImageSummary>? images;
}

/// TRI-01's checklist over [inputs], read-only and without an LLM, in
/// [DoctorCheckKind]'s order.
List<DoctorCheck> doctorChecks(DoctorInputs inputs) => [
  _disk(inputs, DoctorCheckKind.diskSpace, DiskMeasure.space),
  _disk(inputs, DoctorCheckKind.inodes, DiskMeasure.inodes),
  _failedUnits(inputs.failedUnits),
  ..._packages(inputs),
  _timeSync(inputs.profile, inputs.skew),
  _certificates(inputs),
  if (inputs.docker) ...[
    _dockerDiskUse(inputs.diskUse),
    _danglingImages(inputs.images),
  ],
];

DoctorCheck _disk(
  DoctorInputs inputs,
  DoctorCheckKind kind,
  DiskMeasure measure,
) {
  final fs = inputs.fs;
  if (fs == null || inputs.fsFailed) {
    return DoctorCheck(kind, DoctorVerdict.unknown);
  }

  final alarms = [
    for (final alarm in diskAlarms(fs))
      if (alarm.measure == measure) alarm,
  ];
  if (alarms.isEmpty) return DoctorCheck(kind, DoctorVerdict.ok);
  return DoctorCheck(
    kind,
    alarms.first.severity == ChartSeverity.critical
        ? DoctorVerdict.problem
        : DoctorVerdict.warning,
    names: [for (final alarm in alarms) alarm.mountPoint],
    count: alarms.first.percent,
  );
}

DoctorCheck _failedUnits(List<SystemdUnit>? failed) => switch (failed) {
  null => const DoctorCheck(DoctorCheckKind.failedUnits, DoctorVerdict.unknown),
  [] => const DoctorCheck(DoctorCheckKind.failedUnits, DoctorVerdict.ok),
  _ => DoctorCheck(
    DoctorCheckKind.failedUnits,
    DoctorVerdict.problem,
    count: failed.length,
    names: [for (final unit in failed) unit.unit],
  ),
};

List<DoctorCheck> _packages(DoctorInputs inputs) {
  if (inputs.packagesReading) {
    return const [
      DoctorCheck(DoctorCheckKind.securityUpdates, DoctorVerdict.checking),
      DoctorCheck(DoctorCheckKind.rebootRequired, DoctorVerdict.checking),
    ];
  }
  final check = inputs.packages?.check;
  if (check == null || inputs.packages?.failure != null) {
    return const [
      DoctorCheck(DoctorCheckKind.securityUpdates, DoctorVerdict.unknown),
      DoctorCheck(DoctorCheckKind.rebootRequired, DoctorVerdict.unknown),
    ];
  }

  final updates = check.updates.length;
  final security = check.securityCount;
  return [
    if (check.failure != null)
      const DoctorCheck(DoctorCheckKind.securityUpdates, DoctorVerdict.unknown)
    else if (security != null && security > 0)
      DoctorCheck(
        DoctorCheckKind.securityUpdates,
        DoctorVerdict.problem,
        count: security,
      )
    else if (security == null && updates > 0)
      DoctorCheck(
        DoctorCheckKind.securityUpdates,
        DoctorVerdict.warning,
        count: updates,
      )
    else
      DoctorCheck(
        DoctorCheckKind.securityUpdates,
        DoctorVerdict.ok,
        count: updates,
      ),
    switch (check.reboot) {
      RebootState.required => DoctorCheck(
        DoctorCheckKind.rebootRequired,
        DoctorVerdict.warning,
        names: check.rebootPackages,
      ),
      RebootState.notRequired => const DoctorCheck(
        DoctorCheckKind.rebootRequired,
        DoctorVerdict.ok,
      ),
      RebootState.unknown => const DoctorCheck(
        DoctorCheckKind.rebootRequired,
        DoctorVerdict.unknown,
      ),
    },
  ];
}

/// The kernel's synchronized flag wins over timedated's NTP switch, as on
/// the System tab; a clock off this device's by more than [kClockInStep]
/// warns even when the host believes it is synchronized.
DoctorCheck _timeSync(HostProfile? profile, Duration? skew) {
  const kind = DoctorCheckKind.timeSync;
  final synchronized = profile?.ntpSynchronized;
  if (synchronized == false ||
      (synchronized == null && profile?.ntpEnabled == false)) {
    return DoctorCheck(kind, DoctorVerdict.problem, skew: skew);
  }
  if (skew != null && skew.abs() >= kClockInStep) {
    return DoctorCheck(kind, DoctorVerdict.warning, skew: skew);
  }
  if (synchronized == true || skew != null) {
    return DoctorCheck(kind, DoctorVerdict.ok, skew: skew);
  }
  return const DoctorCheck(kind, DoctorVerdict.unknown);
}

DoctorCheck _certificates(DoctorInputs inputs) {
  const kind = DoctorCheckKind.certificates;
  if (inputs.endpoints.isEmpty) {
    return const DoctorCheck(kind, DoctorVerdict.notSetUp);
  }
  if (inputs.tlsChecking) {
    return const DoctorCheck(kind, DoctorVerdict.checking);
  }
  final checks = inputs.tlsChecks;
  if (checks == null) return const DoctorCheck(kind, DoctorVerdict.unknown);

  final failing = <String>[];
  final expiring = <String>[];
  for (final check in checks) {
    final notAfter = check.certificate?.notAfter;
    if (check.failure != null ||
        !check.trusted ||
        notAfter == null ||
        !notAfter.isAfter(inputs.now)) {
      failing.add(check.endpoint.label);
    } else if (notAfter.difference(inputs.now) < kTlsExpirySoon) {
      expiring.add(check.endpoint.label);
    }
  }
  if (failing.isEmpty && expiring.isEmpty) {
    return DoctorCheck(kind, DoctorVerdict.ok, count: checks.length);
  }
  return DoctorCheck(
    kind,
    failing.isEmpty ? DoctorVerdict.warning : DoctorVerdict.problem,
    names: [...failing, ...expiring],
  );
}

DoctorCheck _dockerDiskUse(DockerDiskUse? use) {
  const kind = DoctorCheckKind.dockerDiskUse;
  final reclaimable = use?.df?.reclaimable;
  if (reclaimable == null) {
    return DoctorCheck(
      kind,
      use?.inFlight ?? false ? DoctorVerdict.checking : DoctorVerdict.unknown,
    );
  }
  return DoctorCheck(
    kind,
    reclaimable >= _reclaimableBytes ? DoctorVerdict.warning : DoctorVerdict.ok,
    bytes: reclaimable,
  );
}

DoctorCheck _danglingImages(List<ImageSummary>? images) {
  const kind = DoctorCheckKind.danglingImages;
  if (images == null) return const DoctorCheck(kind, DoctorVerdict.unknown);

  final dangling = [
    for (final image in images)
      if (imageTagsOf(image).isEmpty) image,
  ];
  if (dangling.isEmpty) return const DoctorCheck(kind, DoctorVerdict.ok);
  return DoctorCheck(
    kind,
    DoctorVerdict.warning,
    count: dangling.length,
    bytes: dangling.fold<int>(0, (sum, image) => sum + (image.size ?? 0)),
  );
}

/// The widest the doctor grows on a wide window.
const double _dialogMaxWidth = 560;

/// The window width below which the doctor opens as a bottom sheet.
const double _phoneMaxWidth = 600;

/// Opens TRI-01's doctor for [serverId] over [context]: a bottom sheet on
/// phones, a dialog on wider windows. It runs its checks as it opens.
Future<void> showDoctor(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
}) {
  final style = MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null;
  final view = DoctorView(monitoring: monitoring, serverId: serverId);
  if (MediaQuery.sizeOf(context).width < _phoneMaxWidth) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: style,
      builder: (_) => view,
    );
  }
  return showDialog<void>(
    context: context,
    animationStyle: style,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: view,
      ),
    ),
  );
}

/// TRI-01's checklist for [serverId]. The disk, unit, clock and Docker
/// checks read what the Overview holds; the package check, the endpoint
/// certificates and Docker's disk use are read as it opens and on
/// request. Nothing on the server changes.
class DoctorView extends StatefulWidget {
  const DoctorView({
    super.key,
    required this.monitoring,
    required this.serverId,
    this.now = DateTime.now,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The clock certificate expiry counts from.
  final DateTime Function() now;

  @override
  State<DoctorView> createState() => _DoctorViewState();
}

class _DoctorViewState extends State<DoctorView> {
  PackagesReport? _packages;
  bool _packagesReading = false;
  List<TlsEndpoint> _endpoints = const [];
  List<TlsEndpointCheck>? _tlsChecks;
  bool _tlsChecking = false;

  /// Bumped per run, so only the newest answers land.
  int _ticket = 0;

  MonitoringController get _monitoring => widget.monitoring;
  DockerController get _docker => _monitoring.docker;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _run() {
    final ticket = ++_ticket;
    final serverId = widget.serverId;
    _packages = null;
    _packagesReading = true;
    _endpoints = _monitoring.tlsEndpoints.endpointsFor(serverId);
    _tlsChecks = null;
    _tlsChecking = _endpoints.isNotEmpty;

    unawaited(
      _monitoring.packages.read(serverId).then((report) {
        if (!mounted || ticket != _ticket) return;
        setState(() {
          _packages = report;
          _packagesReading = false;
        });
      }),
    );
    if (_endpoints.isNotEmpty) {
      unawaited(
        _monitoring.checkTlsEndpoints(_endpoints).then((checks) {
          if (!mounted || ticket != _ticket) return;
          setState(() {
            _tlsChecks = checks;
            _tlsChecking = false;
          });
        }),
      );
    }
    if (_docker.endpointFor(serverId).value?.phase ==
        DockerEndpointPhase.ready) {
      _docker.measureDiskUse(serverId);
    }
  }

  void _again() => setState(_run);

  @override
  Widget build(BuildContext context) {
    final serverId = widget.serverId;
    final fsLatest = _monitoring.sampleFor(serverId, SampleStream.fs);
    final fsListed = _monitoring.lastReadingFor(serverId, SampleStream.fs);
    final units = _monitoring.lastReadingFor(
      serverId,
      SampleStream.failedUnits,
    );
    final profile = _monitoring.profileFor(serverId);
    final clock = _monitoring.clockFor(serverId);
    final endpoint = _docker.endpointFor(serverId);
    final containers = _docker.containersFor(serverId);
    final images = _docker.imagesFor(serverId);
    final diskUse = _docker.diskUseFor(serverId);
    final List<ValueListenable<Object?>> watched = [
      fsLatest,
      fsListed,
      units,
      profile,
      clock,
      endpoint,
      containers,
      images,
      diskUse,
    ];

    return ListenableBuilder(
      listenable: Listenable.merge(watched),
      builder: (context, _) {
        // As the Overview's Docker card: a server shows Docker once its
        // endpoint is ready or lists from one are held.
        final docker =
            endpoint.value?.phase == DockerEndpointPhase.ready ||
            containers.value.containers != null;
        final checks = doctorChecks(
          DoctorInputs(
            now: widget.now(),
            fs: switch (fsListed.value?.result) {
              FsResult(:final fs) => fs,
              _ => null,
            },
            fsFailed: fsLatest.value?.result is CollectorUnavailable,
            failedUnits: switch (units.value?.result) {
              FailedUnitsResult(:final failed) => failed,
              _ => null,
            },
            profile: profile.value,
            skew: clock.value?.skew,
            packages: _packages,
            packagesReading: _packagesReading,
            endpoints: _endpoints,
            tlsChecks: _tlsChecks,
            tlsChecking: _tlsChecking,
            docker: docker,
            diskUse: diskUse.value,
            images: images.value.images,
          ),
        );
        return _DoctorList(checks: checks, onAgain: _again);
      },
    );
  }
}

class _DoctorList extends StatelessWidget {
  const _DoctorList({required this.checks, required this.onAgain});

  final List<DoctorCheck> checks;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problems = checks
        .where((check) => check.verdict == DoctorVerdict.problem)
        .length;
    final warnings = checks
        .where((check) => check.verdict == DoctorVerdict.warning)
        .length;
    final checking = checks.any(
      (check) => check.verdict == DoctorVerdict.checking,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(l10n.doctorTitle, style: theme.textTheme.titleLarge),
          Text(l10n.doctorIntro, style: theme.textTheme.bodyMedium),
          Semantics(
            liveRegion: true,
            child: Text(
              checking
                  ? l10n.doctorRunning
                  : l10n.doctorSummary(problems, warnings),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final check in checks) DoctorRow(check: check),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: checking ? null : onAgain,
                  child: Text(l10n.doctorAgain),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(l10n.doctorClose),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the doctor's checklist: the check, what it found, the
/// mounts, units, packages or endpoints concerned, and for a finding
/// what to do about it.
class DoctorRow extends StatelessWidget {
  const DoctorRow({super.key, required this.check});

  final DoctorCheck check;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final verdict = check.verdict;
    final (icon, color) = switch (verdict) {
      DoctorVerdict.problem => (Icons.error_outline, scheme.error),
      DoctorVerdict.warning => (Icons.warning_amber, scheme.tertiary),
      DoctorVerdict.unknown => (Icons.help_outline, scheme.onSurfaceVariant),
      DoctorVerdict.checking => (
        Icons.hourglass_empty,
        scheme.onSurfaceVariant,
      ),
      DoctorVerdict.notSetUp => (
        Icons.remove_circle_outline,
        scheme.onSurfaceVariant,
      ),
      DoctorVerdict.ok => (Icons.check_circle_outline, scheme.primary),
    };
    final actionable =
        verdict == DoctorVerdict.problem ||
        verdict == DoctorVerdict.warning ||
        verdict == DoctorVerdict.notSetUp;

    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 20, color: color),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  l10n.doctorCheck(check.kind.name),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(_finding(l10n), style: theme.textTheme.bodyMedium),
                for (final name in check.names)
                  SelectableText(name, style: muted),
                if (actionable)
                  Text(
                    verdict == DoctorVerdict.notSetUp
                        ? l10n.doctorCertificatesSetUp
                        : l10n.doctorHint(check.kind.name),
                    style: muted,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _finding(AppLocalizations l10n) {
    final count = check.count ?? 0;
    final size = ghostFormatBinarySize(check.bytes ?? 0);
    final warning = l10n.chartPercent(kDefaultThresholds.warning / 100);
    return switch ((check.kind, check.verdict)) {
      (_, DoctorVerdict.unknown) => l10n.doctorUnknown,
      (_, DoctorVerdict.checking) => l10n.doctorChecking,
      (DoctorCheckKind.certificates, DoctorVerdict.notSetUp) =>
        l10n.doctorCertificatesNone,
      (DoctorCheckKind.diskSpace, DoctorVerdict.ok) => l10n.doctorSpaceOk(
        warning,
      ),
      (DoctorCheckKind.diskSpace, _) => l10n.doctorSpaceFull(
        l10n.chartPercent(count / 100),
      ),
      (DoctorCheckKind.inodes, DoctorVerdict.ok) => l10n.doctorInodesOk(
        warning,
      ),
      (DoctorCheckKind.inodes, _) => l10n.doctorInodesFull(
        l10n.chartPercent(count / 100),
      ),
      (DoctorCheckKind.failedUnits, DoctorVerdict.ok) => l10n.doctorUnitsOk,
      (DoctorCheckKind.failedUnits, _) => l10n.doctorUnitsFailed(count),
      (DoctorCheckKind.securityUpdates, DoctorVerdict.problem) =>
        l10n.doctorSecurityPending(count),
      (DoctorCheckKind.securityUpdates, DoctorVerdict.warning) =>
        l10n.doctorUpdatesUnclassified(count),
      (DoctorCheckKind.securityUpdates, _) => l10n.doctorSecurityNone(count),
      (DoctorCheckKind.rebootRequired, DoctorVerdict.ok) => l10n.doctorRebootNo,
      (DoctorCheckKind.rebootRequired, _) => l10n.doctorRebootYes,
      (DoctorCheckKind.timeSync, DoctorVerdict.problem) =>
        check.skew == null
            ? l10n.doctorTimeNotSynced
            : l10n.doctorTimeNotSyncedSkew(clockSkewText(l10n, check.skew)!),
      (DoctorCheckKind.timeSync, DoctorVerdict.warning) => l10n.doctorClockOff(
        clockSkewText(l10n, check.skew)!,
      ),
      (DoctorCheckKind.timeSync, _) => l10n.doctorTimeOk,
      (DoctorCheckKind.certificates, DoctorVerdict.ok) =>
        l10n.doctorCertificatesOk(count),
      (DoctorCheckKind.certificates, _) => l10n.doctorCertificatesBad,
      (DoctorCheckKind.dockerDiskUse, _) => l10n.doctorDockerReclaimable(size),
      (DoctorCheckKind.danglingImages, DoctorVerdict.ok) =>
        l10n.doctorDanglingNone,
      (DoctorCheckKind.danglingImages, _) => l10n.doctorDangling(count, size),
    };
  }
}

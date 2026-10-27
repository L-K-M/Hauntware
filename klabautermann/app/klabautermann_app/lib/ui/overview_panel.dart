import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/docker_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'cpu_hints.dart';
import 'docker/containers_view.dart' show containerNameOf;
import 'failed_units_summary.dart';
import 'fleet_row_state.dart' show kFleetRowStaleAfter;
import 'freshness.dart';
import 'history_card.dart';
import 'slowness.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;
import 'system_view.dart';
import 'threshold_announcer.dart';
import 'threshold_scope.dart';

/// The panel width from which the cards sit in two columns, growing with
/// the text scale as the System tab's does.
const double _wideWidth = 600;

const double _gap = 16;
const double _sparklineHeight = 40;

/// A per-core bar's width with its figure's box, beside the core's name,
/// before text scaling, and the gap between a core's name, bar and figure.
const double _coreBarAndFigureWidth = 106;
const double _coreGap = 8;

/// The widest a core's name gets before text scaling; only a name no
/// kernel prints, such as a broken host's, is cut there.
const double _coreNameMaxWidth = 72;

/// The limit for the slow streams the health and Disks cards read (03
/// §6.4): `fs` every 30 to 120 s and `failedUnits` every 60 s, so the
/// fleet rows' `fs` limit, twice the slowest, judges both.
final Duration _slowStaleAfter = kFleetRowStaleAfter[SampleStream.fs]!;

/// How many mounts the Disks card lists before pointing to the System tab,
/// which lists them all; the health card names every full one.
const int _maxMountsShown = 8;

/// How many unhealthy containers the health card names before "and N
/// more", as the failed units summary does.
const int _maxUnhealthyShown = 5;

/// The trailing number of a `/proc/stat` core name such as `cpu12`.
final RegExp _coreNumber = RegExp(r'\d+$');

/// [perCpu]'s cores in the host's numeric order, `cpu2` before `cpu10`; a
/// name without a number, or with one past any integer, follows the
/// numbered ones. The names are server data, which the host parser takes
/// with any number of digits, so this never throws on them.
List<(String, double)> orderedCores(Map<String, double> perCpu) {
  num number(String name) => switch (_coreNumber.firstMatch(name)) {
    final match? => int.tryParse(match[0]!) ?? double.infinity,
    null => double.infinity,
  };
  return [for (final MapEntry(:key, :value) in perCpu.entries) (key, value)]
    ..sort((a, b) {
      final byNumber = number(a.$1).compareTo(number(b.$1));
      return byNumber != 0 ? byNumber : a.$1.compareTo(b.$1);
    });
}

/// The Overview tab (03 §10.4; OV-01 to OV-04): the health card from
/// failed units and full disks (OV-02), CPU in total and per core (CPU-01,
/// CPU-02), load with core context (CPU-03), memory with the ZFS ARC note
/// (MEM-01) and swap (MEM-02), with session sparklines from the
/// controller's rings and bar gauges, then the mounts (DSK-01, DSK-02),
/// network throughput (NET-01), and the host's OS, kernel, uptime and
/// boot time (SYS-01, BOOT-01). With a Docker endpoint, the health card
/// adds the unhealthy containers and the Docker card gives OV-05's
/// summary from the containers and images it watches while [visible]
/// ([DockerController.watchSummary]), with the reclaimable space on
/// demand; a server without one shows neither.
///
/// It shows the last reading of each stream its [SampledSurface]
/// subscribes, under freshness lines in 9.5 item 4's words, and greys the
/// values once a line says stale. A failed reading says why above them.
/// Figures go through the chart formatters' IEC units (A11Y-06); what the
/// host did not report reads "Unknown" or is hatched, and a figure a
/// container withholds (D50) says so. The clock ticks only while
/// [visible], and threshold-band changes are announced only then
/// (A11Y-15, [ThresholdAnnouncer]).
class OverviewPanel extends StatelessWidget {
  const OverviewPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
    this.coverage,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Whether the panel's tab shows; see [SampledSurface.visible].
  final bool visible;

  /// The server's coverage card (03 §9.5 item 3), under the cards at the
  /// full width; the workspace and the phone's screen compose it.
  final Widget? coverage;

  /// What the panel listens to instead of the clock while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final latest = monitoring.sampleFor(serverId, SampleStream.core);
    final reading = monitoring.lastReadingFor(serverId, SampleStream.core);
    final sampling = monitoring.samplingFor(serverId);
    final slow = _Slow(monitoring, serverId);
    final docker = _Docker(monitoring.docker, serverId);
    final scope = AnnouncementScope.maybeOf(context);
    // False while a pushed route, such as a phone's Settings, covers the
    // panel; it rebuilds when that changes.
    final onstage = TickerMode.valuesOf(context).enabled;
    return ThresholdAnnouncer(
      core: latest,
      fs: slow.fs,
      active: visible && onstage && (scope?.notifier?.value ?? false),
      child: _DockerSummaryWatch(
        docker: monitoring.docker,
        serverId: serverId,
        visible: visible,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            latest,
            reading,
            sampling,
            ...slow.all,
            ...docker.all,
          ]),
          builder: (context, _) => ListenableBuilder(
            listenable: visible && (reading.value != null || slow.aging)
                ? monitoring.clock
                : _silent,
            builder: (context, _) => _build(
              context,
              latest.value,
              reading.value,
              sampling.value,
              slow,
              docker,
              scope,
            ),
          ),
        ),
      ),
    );
  }

  Widget _build(
    BuildContext context,
    Sample? latest,
    Sample? reading,
    SamplingStatus? sampling,
    _Slow slow,
    _Docker docker,
    AnnouncementScope? scope,
  ) {
    final l10n = AppLocalizations.of(context);
    Freshness freshness(Duration staleAfter, DateTime? lastSampleAt) =>
        freshnessOf(
          now: monitoring.clock.value,
          staleAfter: staleAfter,
          lastSampleAt: lastSampleAt,
          // No monitor set watches a server yet (FL-21): this panel
          // samples it while it shows.
          watched: false,
          sampling: sampling,
        );
    final coreFreshness = freshness(
      kFleetRowStaleAfter[SampleStream.core]!,
      reading?.at,
    );
    final unavailable = switch (latest?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final cards = switch (reading?.result) {
      final CoreResult core => _Cards(
        monitoring: monitoring,
        serverId: serverId,
        core: core,
        stale: coreFreshness.stale,
      ),
      _ => null,
    };
    final partTwo = _PartTwo(
      slow: slow,
      docker: docker,
      core: cards?.core,
      coreStale: coreFreshness.stale,
      diskFreshness: freshness(_slowStaleAfter, slow.listed.value?.at),
      healthFreshness: freshness(_slowStaleAfter, slow.healthAt),
    );
    // Without a `core` reading this run, `core` has no age to lose, so a
    // link lost after slow readings is said from theirs.
    final head = reading != null || coreFreshness is FreshnessPaused
        ? coreFreshness
        : [
            partTwo.diskFreshness,
            partTwo.healthFreshness,
          ].whereType<FreshnessDisconnected>().firstOrNull;

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        Widget column(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: _gap,
          children: children,
        );
        Widget row(Widget start, Widget end) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: _gap,
          children: [
            Expanded(child: start),
            Expanded(child: end),
          ],
        );
        final disks = partTwo.disks(context);
        final host = partTwo.host(context);
        final dockerCard = docker.shown
            ? _DockerCard(
                docker: docker,
                controller: monitoring.docker,
                serverId: serverId,
              )
            : null;
        return SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: column([
            // The live stream's line heads the panel: a pause or a lost
            // link holds every card, and the slow cards add their age.
            if (head != null)
              PanelNotice(
                icon: head.stale ? Icons.history : Icons.schedule,
                text: freshnessText(l10n, head),
              ),
            partTwo.health(context, scope),
            if (unavailable != null)
              PanelNotice(
                icon: unavailable.reason == CollectorUnavailableReason.timeout
                    ? Icons.timer_off_outlined
                    : Icons.error_outline,
                text: l10n.overviewUnavailable(unavailable.reason.name),
                detail: unavailable.detail,
              )
            else if (cards == null)
              PanelNotice(
                icon: Icons.hourglass_empty,
                text: l10n.overviewWaiting,
              ),
            // TRI-02 answers the question the cards below are read for.
            ?cards?.slowness(context),
            if (cards != null && wide) ...[
              row(
                column([
                  cards.cpu(context),
                  cards.load(context),
                  cards.pressure(context),
                ]),
                column([cards.memory(context), cards.swap(context)]),
              ),
              row(disks, column([cards.network(context), host, ?dockerCard])),
            ] else if (wide)
              row(disks, dockerCard == null ? host : column([host, dockerCard]))
            else ...[
              if (cards != null) ...[
                cards.cpu(context),
                cards.load(context),
                cards.memory(context),
                cards.swap(context),
                cards.pressure(context),
              ],
              disks,
              ?cards?.network(context),
              host,
              ?dockerCard,
            ],
            HistoryCard(reads: monitoring.rollups, serverId: serverId),
            ?coverage,
          ]),
        );
      },
    );
  }
}

/// What a [DiskAlarm] measures of its mount.
enum DiskMeasure { space, inodes }

/// A listed mount whose space or inode use is at or past a level (OV-02).
typedef DiskAlarm = ({
  String mountPoint,
  DiskMeasure measure,
  int percent,
  ChartSeverity severity,
});

/// [fs]'s mounts whose space or inode use reaches [levels]' warning level
/// (OV-02, OV-11), the most severe and fullest first; the careful band
/// raises none. Pseudo filesystems stay out, as in the Disks card: a
/// squashfs image is always full.
List<DiskAlarm> diskAlarms(
  FsSnapshot fs, {
  ChartThresholds levels = kDefaultThresholds,
}) {
  final alarms = <DiskAlarm>[];
  for (final mount in shownMounts(fs, showPseudo: false)) {
    for (final (measure, percent) in [
      (DiskMeasure.space, mount.capacityPercent),
      (DiskMeasure.inodes, mount.inodeUsePercent),
    ]) {
      if (percent == null) continue;
      final severity = levels.severityOf(percent.toDouble());
      if (!severity.alarms) continue;
      alarms.add((
        mountPoint: mount.mountPoint,
        measure: measure,
        percent: percent,
        severity: severity,
      ));
    }
  }
  return alarms..sort((a, b) {
    final bySeverity = b.severity.index.compareTo(a.severity.index);
    return bySeverity != 0 ? bySeverity : b.percent.compareTo(a.percent);
  });
}

/// The slow streams the health, Disks and Host cards read (03 §6.4), each
/// as its latest sample, which says when a reading failed, and its last
/// reading, which stays shown meanwhile; and the probe's profile for D50.
final class _Slow {
  _Slow(MonitoringController monitoring, String serverId)
    : fs = monitoring.sampleFor(serverId, SampleStream.fs),
      listed = monitoring.lastReadingFor(serverId, SampleStream.fs),
      failed = monitoring.sampleFor(serverId, SampleStream.failedUnits),
      failedReading = monitoring.lastReadingFor(
        serverId,
        SampleStream.failedUnits,
      ),
      identityLatest = monitoring.sampleFor(serverId, SampleStream.identity),
      identity = monitoring.lastReadingFor(serverId, SampleStream.identity),
      profile = monitoring.profileFor(serverId);

  final ValueListenable<Sample?> fs, listed, failed, failedReading;
  final ValueListenable<Sample?> identityLatest, identity;
  final ValueListenable<HostProfile?> profile;

  List<Listenable> get all => [
    fs,
    listed,
    failed,
    failedReading,
    identityLatest,
    identity,
    profile,
  ];

  /// Whether a reading ages on a freshness line.
  bool get aging => listed.value != null || failedReading.value != null;

  /// The latest `df`'s failure, or null.
  CollectorUnavailable? get fsFailure => switch (fs.value?.result) {
    final CollectorUnavailable unavailable => unavailable,
    _ => null,
  };

  /// When the oldest reading the health card shows arrived: the last unit
  /// list, and the last listing unless the latest `df` failed, since the
  /// card then names no mount from it.
  DateTime? get healthAt {
    final times = [
      ?failedReading.value?.at,
      if (fsFailure == null) ?listed.value?.at,
    ];
    return times.isEmpty ? null : times.reduce((a, b) => a.isBefore(b) ? a : b);
  }
}

/// The server's Docker lists and disk use as the Overview reads them
/// (OV-02, OV-05).
final class _Docker {
  _Docker(DockerController docker, String serverId)
    : endpoint = docker.endpointFor(serverId),
      containers = docker.containersFor(serverId),
      images = docker.imagesFor(serverId),
      diskUse = docker.diskUseFor(serverId);

  final ValueListenable<DockerEndpointState?> endpoint;
  final ValueListenable<DockerContainerList> containers;
  final ValueListenable<DockerImageList> images;
  final ValueListenable<DockerDiskUse> diskUse;

  List<Listenable> get all => [endpoint, containers, images, diskUse];

  bool get ready => endpoint.value?.phase == DockerEndpointPhase.ready;

  /// Whether the server has shown a Docker endpoint: it is ready, or
  /// lists from one are held. A server without Docker never gets one,
  /// and the Overview names no Docker card or container for it.
  bool get shown => ready || containers.value.containers != null;

  /// Whether the lists held are no longer followed: the endpoint is not
  /// ready, so nothing reads them again.
  bool get stale => !ready;
}

/// Holds the server's summary watch while the Overview [visible]
/// ([DockerController.watchSummary]); the controller sends it once the
/// endpoint is ready.
class _DockerSummaryWatch extends StatefulWidget {
  const _DockerSummaryWatch({
    required this.docker,
    required this.serverId,
    required this.visible,
    required this.child,
  });

  final DockerController docker;
  final String serverId;
  final bool visible;
  final Widget child;

  @override
  State<_DockerSummaryWatch> createState() => _DockerSummaryWatchState();
}

class _DockerSummaryWatchState extends State<_DockerSummaryWatch> {
  /// The server [DockerController.watchSummary] was told of, if any.
  String? _held;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DockerSummaryWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.docker == oldWidget.docker,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
    _sync();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    widget.docker.watchSummary(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    widget.docker.unwatchSummary(held);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// OV-05's Docker summary (03 §7.1): container counts as `docker info`
/// splits them and the image counts from the watched lists, and the
/// reclaimable space from `/system/df`, measured only when asked since
/// it is slow on large hosts. Once the endpoint is not ready, the last
/// figures grey under the time they were read.
class _DockerCard extends StatelessWidget {
  const _DockerCard({
    required this.docker,
    required this.controller,
    required this.serverId,
  });

  final _Docker docker;
  final DockerController controller;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final stale = docker.stale;
    final containerList = docker.containers.value;
    final imageList = docker.images.value;
    final containers = containerList.containers;
    final images = imageList.images;
    final failure = containerList.failure ?? imageList.failure;
    final readAt = [
      ?containerList.at,
      ?imageList.at,
    ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    final diskUse = docker.diskUse.value;
    final summary = containers == null
        ? null
        : dockerSummary(containers, images ?? const [], diskUse.df);
    String count(int value) => l10n.overviewDockerCount(value);
    String? imageCount(int value) => images == null ? null : count(value);

    return PanelSection(
      title: l10n.overviewDockerTitle,
      children: [
        if (stale && readAt != null)
          PanelNotice(
            icon: Icons.history,
            text: l10n.overviewDockerStale(readAt.toLocal()),
          ),
        if (failure != null) ...[
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.overviewDockerListFailed(failure.failure.name),
            detail: failure.detail,
          ),
          if (docker.ready)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => controller.retrySummary(serverId),
                child: Text(l10n.dockerRetry),
              ),
            ),
        ] else if (summary == null || images == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewDockerReading,
          ),
        if (summary != null) ...[
          _Facts(
            stale: stale,
            facts: [
              (l10n.overviewDockerRunning, count(summary.running)),
              (l10n.overviewDockerPaused, count(summary.paused)),
              (l10n.overviewDockerStopped, count(summary.stopped)),
              (l10n.overviewDockerUnhealthy, count(summary.unhealthy)),
            ],
          ),
          _Facts(
            stale: stale,
            facts: [
              (l10n.overviewDockerImages, imageCount(summary.images)),
              (l10n.overviewDockerImagesInUse, imageCount(summary.imagesInUse)),
              (l10n.overviewDockerDangling, imageCount(summary.danglingImages)),
            ],
          ),
        ],
        ..._diskUse(context, l10n, diskUse, stale: stale, muted: muted),
      ],
    );
  }

  /// The reclaimable space, when it was measured, and the action that
  /// measures it, with its progress or why it failed.
  List<Widget> _diskUse(
    BuildContext context,
    AppLocalizations l10n,
    DockerDiskUse diskUse, {
    required bool stale,
    required Color muted,
  }) {
    final theme = Theme.of(context);
    final df = diskUse.df;
    final at = diskUse.at;
    final failure = diskUse.failure;
    final note = theme.textTheme.bodySmall?.copyWith(color: muted);
    return [
      _Facts(
        stale: stale,
        facts: [
          (
            l10n.overviewDockerReclaimable,
            df == null
                ? l10n.overviewDockerNotMeasured
                : _Cards._bytes(l10n, df.reclaimable),
          ),
        ],
      ),
      if (df != null && at != null)
        Text(l10n.overviewDockerMeasured(at.toLocal()), style: note),
      if (diskUse.inFlight)
        MergeSemantics(
          child: Row(
            spacing: 8,
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Expanded(child: Text(l10n.overviewDockerMeasuring)),
            ],
          ),
        )
      else if (failure != null)
        PanelNotice(
          icon: Icons.error_outline,
          text: l10n.overviewDockerMeasureFailed(failure.failure.name),
          detail: failure.detail,
        )
      else if (df == null)
        Text(l10n.overviewDockerMeasureNote, style: note),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: docker.ready && !diskUse.inFlight
              ? () => controller.measureDiskUse(serverId)
              : null,
          icon: const Icon(Icons.data_usage),
          label: Text(
            df == null
                ? l10n.overviewDockerMeasure
                : l10n.overviewDockerMeasureAgain,
          ),
        ),
      ),
    ];
  }
}

/// OV-02's unhealthy containers beside the failed units: how many, then
/// each one's name with the engine's status text, in the failed units
/// summary's shape. The Docker tab has no route to one container yet,
/// so the names are plain text.
class _UnhealthyContainers extends StatelessWidget {
  const _UnhealthyContainers({required this.unhealthy, required this.stale});

  final List<ContainerSummary> unhealthy;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final none = unhealthy.isEmpty;
    final color = none || stale
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    final hidden = unhealthy.length - _maxUnhealthyShown;
    final line = stale
        ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Semantics(
          header: true,
          child: Row(
            spacing: 8,
            children: [
              Icon(
                none ? Icons.check_circle_outline : Icons.error_outline,
                color: color,
                size: 20,
              ),
              Flexible(
                child: Text(
                  l10n.overviewHealthContainersUnhealthy(unhealthy.length),
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
        for (final container in unhealthy.take(_maxUnhealthyShown))
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text(
              l10n.overviewHealthContainer(
                containerNameOf(container),
                container.status ?? l10n.chartUnknownValue,
              ),
              style: line,
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text(
              l10n.servicesFailedMore(hidden),
              style: theme.textTheme.bodySmall?.copyWith(
                color: stale ? theme.colorScheme.onSurfaceVariant : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// How the health card's link words the A11Y-15 switch.
enum _SwitchState { on, off }

/// The health, Disks and Host cards over [slow]'s readings and the `core`
/// reading's uptime and boot time.
final class _PartTwo {
  const _PartTwo({
    required this.slow,
    required this.docker,
    required this.core,
    required this.coreStale,
    required this.diskFreshness,
    required this.healthFreshness,
  });

  final _Slow slow;
  final _Docker docker;
  final CoreResult? core;
  final bool coreStale;
  final Freshness diskFreshness, healthFreshness;

  /// A slow card's age, or null: a pause or a lost link is said once, by
  /// the panel's first line, though it greys these values too.
  static Widget? _ageLine(AppLocalizations l10n, Freshness freshness) =>
      freshness is FreshnessUpdated
      ? PanelNotice(
          icon: freshness.stale ? Icons.history : Icons.schedule,
          text: freshnessText(l10n, freshness),
        )
      : null;

  static IconData _reasonIcon(CollectorUnavailable unavailable) =>
      unavailable.reason == CollectorUnavailableReason.timeout
      ? Icons.timer_off_outlined
      : Icons.error_outline;

  /// OV-02: failed units through K34's summary and, with a Docker
  /// endpoint, the unhealthy containers, then the mounts past a level, and
  /// the link to A11Y-15's switch in Settings (D60).
  Widget health(BuildContext context, AnnouncementScope? scope) {
    final l10n = AppLocalizations.of(context);
    final stale = healthFreshness.stale;
    final unitsFailed = switch (slow.failed.value?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final announce = scope?.notifier?.value ?? false;
    return PanelSection(
      title: l10n.overviewHealthTitle,
      children: [
        ?_ageLine(l10n, healthFreshness),
        if (unitsFailed != null)
          PanelNotice(
            icon: _reasonIcon(unitsFailed),
            text: l10n.overviewHealthUnitsCheckFailed(unitsFailed.reason.name),
            detail: unitsFailed.detail,
          ),
        if (slow.failedReading.value?.result case FailedUnitsResult(
          :final failed,
        ))
          FailedUnitsSummary(failed: failed, stale: stale)
        else if (unitsFailed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewHealthUnitsWaiting,
          ),
        if (docker.shown)
          if (docker.containers.value.containers case final containers?)
            _UnhealthyContainers(
              unhealthy: [
                for (final container in containers)
                  if (container.health == HealthStatus.unhealthy) container,
              ],
              stale: docker.stale,
            ),
        ..._diskHealth(context, l10n, stale),
        if (scope != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            // The label states the switch, so the hint says that the
            // button opens Settings rather than flipping it here.
            child: MergeSemantics(
              child: Semantics(
                hint: l10n.overviewHealthAnnouncementsHint,
                child: TextButton.icon(
                  onPressed: () => scope.openSettings(context),
                  icon: Icon(
                    announce
                        ? Icons.record_voice_over_outlined
                        : Icons.voice_over_off_outlined,
                  ),
                  label: Text(
                    l10n.overviewHealthAnnouncements(
                      (announce ? _SwitchState.on : _SwitchState.off).name,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A failed `df` makes every mount's use unknown, so it names no mount
  /// from an older reading.
  List<Widget> _diskHealth(
    BuildContext context,
    AppLocalizations l10n,
    bool stale,
  ) {
    if (slow.fsFailure case final unavailable?) {
      return [
        PanelNotice(
          icon: _reasonIcon(unavailable),
          text: l10n.overviewHealthDisksUnknown(unavailable.reason.name),
        ),
      ];
    }
    final listed = slow.listed.value?.result;
    if (listed is! FsResult) {
      return [
        PanelNotice(
          icon: Icons.hourglass_empty,
          text: l10n.overviewDisksWaiting,
        ),
      ];
    }

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final levels = ThresholdScope.of(context, ThresholdMetric.disk);
    final alarms = diskAlarms(listed.fs, levels: levels);
    if (alarms.isEmpty) {
      return [
        _IconLine(
          icon: Icons.check_circle_outline,
          color: muted,
          text: l10n.overviewHealthDisksOk(
            l10n.chartPercent(levels.warning / 100),
          ),
          stale: stale,
        ),
      ];
    }
    final palette = ChartPalette.of(context);
    return [
      for (final alarm in alarms)
        _IconLine(
          icon: alarm.severity == ChartSeverity.critical
              ? Icons.error_outline
              : Icons.warning_amber_outlined,
          color: stale ? muted : palette.severityColor(alarm.severity) ?? muted,
          text: switch (alarm.measure) {
            DiskMeasure.inodes => l10n.overviewHealthDiskInodes(
              alarm.mountPoint,
              l10n.chartPercent(alarm.percent / 100),
              alarm.severity.name,
            ),
            DiskMeasure.space => l10n.overviewHealthDiskSpace(
              alarm.mountPoint,
              l10n.chartPercent(alarm.percent / 100),
              alarm.severity.name,
            ),
          },
          stale: stale,
        ),
    ];
  }

  /// DSK-01 and DSK-02 as K37's System tab reads them: the listed mounts,
  /// after a `df` timeout the last reading's mounts with their use
  /// unknown, since which mount hung is not known, and after another
  /// failure only why.
  Widget disks(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final listed = switch (slow.listed.value) {
      Sample(:final at, result: FsResult(:final fs)) => (at: at, fs: fs),
      _ => null,
    };
    final unavailable = slow.fsFailure;
    final timedOut = unavailable?.reason == CollectorUnavailableReason.timeout;
    final shown = unavailable == null || timedOut ? listed : null;
    return PanelSection(
      title: l10n.systemDisksTitle,
      children: [
        if (shown != null) ?_ageLine(l10n, diskFreshness),
        if (timedOut) ...[
          PanelNotice(
            icon: Icons.timer_off_outlined,
            text: l10n.systemDisksTimedOut,
          ),
          if (listed != null)
            Text(l10n.systemDisksLastListed(listed.at.toLocal())),
        ] else if (unavailable != null)
          PanelNotice(
            icon: _reasonIcon(unavailable),
            text: l10n.overviewUnavailable(unavailable.reason.name),
            detail: unavailable.detail,
          )
        else if (listed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewDisksWaiting,
          )
        else if (listed.fs.timeoutAbsent)
          PanelNotice(
            icon: Icons.info_outline,
            text: l10n.systemDisksNoTimeout,
          ),
        if (shown != null)
          ..._mounts(context, l10n, shown.fs, timedOut: timedOut),
      ],
    );
  }

  List<Widget> _mounts(
    BuildContext context,
    AppLocalizations l10n,
    FsSnapshot fs, {
    required bool timedOut,
  }) {
    final mounts = shownMounts(fs, showPseudo: false);
    if (mounts.isEmpty) return [Text(l10n.systemDisksEmpty)];

    final stale = diskFreshness.stale;
    String? percent(int? value) =>
        value == null || timedOut ? null : l10n.chartPercent(value / 100);
    return [
      for (final mount in mounts.take(_maxMountsShown))
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Text(
              mount.mountPoint,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (!timedOut)
              StackedBar(
                label: mount.mountPoint,
                segments: [
                  BarSegment(
                    label: l10n.systemColumnUsed,
                    value: mount.usedBytes?.toDouble(),
                  ),
                ],
                total: _diskBase(mount)?.toDouble(),
                unit: ChartUnit.bytes,
                strings: klabautermannChartStrings(l10n),
                thresholds: ThresholdScope.of(context, ThresholdMetric.disk),
                stale: stale,
              ),
            _Facts(
              stale: stale,
              facts: [
                (l10n.systemColumnUse, percent(mount.capacityPercent)),
                (
                  l10n.overviewDiskSize,
                  timedOut ? null : _Cards._bytes(l10n, mount.sizeBytes),
                ),
                (l10n.systemColumnInodes, percent(mount.inodeUsePercent)),
              ],
            ),
          ],
        ),
      if (mounts.length > _maxMountsShown)
        Text(l10n.overviewDisksMore(mounts.length - _maxMountsShown)),
    ];
  }

  /// What `df` computes a mount's share on: the used plus the available
  /// space (reserved blocks count in neither), else the size, so bar and
  /// figure agree as in the System tab.
  static int? _diskBase(FsMount mount) {
    final used = mount.usedBytes;
    final avail = mount.availBytes;
    return used != null && avail != null ? used + avail : mount.sizeBytes;
  }

  /// SYS-01's OS and kernel from `identity`, and BOOT-01's uptime and boot
  /// time from `core`, unknown with D50's reason where the container's
  /// `/proc` file would give the host's. Before a reading the card waits,
  /// and a failed one says why above the last values, as the System tab
  /// and part one's cards do; the panel's first notices speak for `core`.
  Widget host(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identityFailed = switch (slow.identityLatest.value?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final identity = switch (slow.identity.value?.result) {
      final IdentityResult identity => identity,
      _ => null,
    };
    final profile = slow.profile.value;
    final uptimeWithheld = withholdsHostFigure(
      profile,
      SystemWideProcFile.uptime,
    );
    final bootWithheld = withholdsHostFigure(profile, SystemWideProcFile.stat);
    final core = this.core;
    final uptime = uptimeWithheld ? null : core?.uptime;
    final booted = bootWithheld ? null : core?.bootedAt;
    return PanelSection(
      title: l10n.overviewHostTitle,
      children: [
        if (identityFailed != null)
          PanelNotice(
            icon: _reasonIcon(identityFailed),
            text: l10n.overviewUnavailable(identityFailed.reason.name),
            detail: identityFailed.detail,
          ),
        if (identity != null)
          // Read once per session (03 §6.4), so with no age of its own:
          // it greys with the `core` cards once the panel's line says
          // stale.
          _Facts(
            stale: core != null && coreStale,
            facts: [
              (l10n.systemOperatingSystem, identity.osPrettyName),
              (l10n.systemKernel, kernelText(l10n, identity)),
            ],
          )
        else if (identityFailed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewHostWaiting,
          ),
        if (core != null) ...[
          _Facts(
            stale: coreStale,
            facts: [
              (
                l10n.systemUptime,
                uptime == null ? null : uptimeText(l10n, uptime),
              ),
              (
                l10n.systemBooted,
                booted == null
                    ? null
                    : l10n.systemBootedValue(booted.toLocal()),
              ),
            ],
          ),
          if (uptimeWithheld || bootWithheld)
            PanelNotice(
              icon: Icons.info_outline,
              text: uptimeWithheld && bootWithheld
                  ? l10n.overviewUnknownContainer
                  : l10n.systemUnknownContainer,
            ),
        ],
      ],
    );
  }
}

/// A state in words beside an icon of its own shape, read as one node;
/// the colour adds emphasis only (A11Y-01).
class _IconLine extends StatelessWidget {
  const _IconLine({
    required this.icon,
    required this.color,
    required this.text,
    required this.stale,
  });

  final IconData icon;
  final Color color;
  final String text;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 20, color: color),
          Expanded(child: Text(text, style: _valueStyle(context, stale))),
        ],
      ),
    );
  }
}

/// The four cards over one `core` reading.
final class _Cards {
  const _Cards({
    required this.monitoring,
    required this.serverId,
    required this.core,
    required this.stale,
  });

  final MonitoringController monitoring;
  final String serverId;
  final CoreResult core;
  final bool stale;

  /// SYS-04's reason, or [text], when the engine withheld any of [fields]
  /// as the container host's (D50); their values are then null.
  Widget? _withheld(
    AppLocalizations l10n,
    List<MetricField> fields, {
    String? text,
  }) => fields.any(core.withheld.containsKey)
      ? PanelNotice(
          icon: Icons.info_outline,
          text: text ?? l10n.overviewUnknownContainer,
        )
      : null;

  /// [series]' session sparkline over its gauge of [segments] out of
  /// [total]. The sparkline's bands are in its own unit, so it takes
  /// [thresholds] only for a share; a gauge judges its first segment's
  /// share of [total].
  List<Widget> _charts(
    BuildContext context, {
    required MetricSeries series,
    required String label,
    required ChartUnit unit,
    required List<BarSegment> segments,
    required double? total,
    ChartThresholds? thresholds,
  }) {
    final strings = klabautermannChartStrings(AppLocalizations.of(context));
    return [
      SizedBox(
        height: _sparklineHeight,
        child: Sparkline(
          series: monitoring.seriesFor(serverId, SampleStream.core, series),
          label: label,
          unit: unit,
          strings: strings,
          max: total != null && total > 0 ? total : null,
          thresholds: unit == ChartUnit.percent ? thresholds : null,
          color: stale ? ChartPalette.of(context).muted : null,
        ),
      ),
      StackedBar(
        label: label,
        segments: segments,
        total: total,
        unit: unit,
        strings: strings,
        thresholds: thresholds,
        stale: stale,
      ),
    ];
  }

  Widget cpu(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final cpu = core.cpu;
    final perCpu = core.perCpu;
    String? percent(double? value) => value == null
        ? null
        : formatChartValue(value, ChartUnit.percent, strings);
    return PanelSection(
      title: l10n.overviewCpuTitle,
      children: [
        ..._charts(
          context,
          series: MetricSeries.cpuBusy,
          label: l10n.overviewCpuTitle,
          unit: ChartUnit.percent,
          segments: [BarSegment(label: l10n.overviewCpuBusy, value: cpu?.busy)],
          total: 100,
          thresholds: ThresholdScope.of(context, ThresholdMetric.cpu),
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewCpuUser, percent(cpu?.user)),
            (l10n.overviewCpuSystem, percent(cpu?.system)),
            (l10n.overviewCpuIdle, percent(cpu?.idle)),
            (l10n.overviewCpuIowait, percent(cpu?.iowait)),
            (l10n.overviewCpuSteal, percent(cpu?.steal)),
            (l10n.overviewCpuIrq, percent(cpu?.irq)),
            (l10n.overviewCpuSoftirq, percent(cpu?.softirq)),
          ],
        ),
        // CPU-04's hints explain what the figures above mean for the
        // host; a stale reading keeps them beside the greyed figures.
        if (cpu != null)
          for (final hint in cpuHints(cpu))
            PanelNotice(
              icon: Icons.lightbulb_outline,
              text: _hintText(l10n, hint, percent(hint.percent)!),
            ),
        Semantics(
          header: true,
          child: Text(
            l10n.overviewPerCoreTitle,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        if (perCpu == null || perCpu.isEmpty)
          _Facts(stale: stale, facts: const [])
        else
          _CoreBars(cores: orderedCores(perCpu), stale: stale),
        // One note for the card: a container withholds both from the same
        // /proc/stat, so two would repeat each other.
        ?_withheld(l10n, const [MetricField.cpu, MetricField.perCpu]),
      ],
    );
  }

  static String _hintText(
    AppLocalizations l10n,
    CpuHint hint,
    String percent,
  ) => switch (hint.kind) {
    CpuHintKind.steal => l10n.overviewCpuHintSteal(percent),
    CpuHintKind.iowait => l10n.overviewCpuHintIowait(percent),
    CpuHintKind.interrupts => l10n.overviewCpuHintInterrupts(percent),
  };

  /// TRI-02: what in this reading slows the server, each in a sentence,
  /// and where to look next.
  Widget slowness(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    String percent(double value) =>
        formatChartValue(value, ChartUnit.percent, strings);
    final signals = slownessSignals(core);
    return PanelSection(
      title: l10n.overviewSlowTitle,
      children: [
        if (signals.isEmpty)
          Text(l10n.overviewSlowNone, style: _valueStyle(context, stale))
        else ...[
          for (final signal in signals)
            PanelNotice(
              icon: Icons.speed,
              text: switch (signal.kind) {
                SlownessKind.cpuWait => l10n.overviewSlowCpuWait(
                  percent(signal.value),
                ),
                SlownessKind.loadHigh => l10n.overviewSlowLoadHigh(
                  signal.value,
                ),
                SlownessKind.steal => l10n.overviewSlowSteal(
                  percent(signal.value),
                ),
                SlownessKind.ioStall => l10n.overviewSlowIoStall(
                  percent(signal.value),
                ),
                SlownessKind.iowait => l10n.overviewSlowIowait(
                  percent(signal.value),
                ),
                SlownessKind.slowDisk => l10n.overviewSlowSlowDisk(
                  signal.device!,
                  signal.value.round(),
                ),
                SlownessKind.busyDisk => l10n.overviewSlowBusyDisk(
                  signal.device!,
                  percent(signal.value),
                ),
                SlownessKind.memoryStall => l10n.overviewSlowMemoryStall(
                  percent(signal.value),
                ),
                SlownessKind.swapHeavy => l10n.overviewSlowSwapHeavy(
                  percent(signal.value),
                ),
              },
            ),
          Text(
            l10n.overviewSlowWhere,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// CPU-05 and MEM-04: how much of the time tasks stalled for CPU,
  /// memory and I/O. A kernel without PSI is normal (7.1), so its absence
  /// is said plainly rather than as a failure.
  Widget pressure(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Two decimals as the kernel prints them: stalls of a fraction of a
    // percent are the usual reading, which whole percents would zero.
    String? averages(StallAverages? line) => line == null
        ? null
        : l10n.overviewPressureValue(line.avg10, line.avg60, line.avg300);

    const fields = [
      MetricField.cpuPressure,
      MetricField.memoryPressure,
      MetricField.ioPressure,
    ];
    final files = [
      (l10n.overviewPressureCpu, core.cpuPressure),
      (l10n.overviewPressureMemory, core.memoryPressure),
      (l10n.overviewPressureIo, core.ioPressure),
    ];
    final withheld = _withheld(l10n, fields);
    final figures = [
      for (final (name, file) in files)
        if (file != null) ...[
          if (file.some != null)
            (l10n.overviewPressureSome(name), averages(file.some)),
          if (file.full != null)
            (l10n.overviewPressureFull(name), averages(file.full)),
        ],
    ];
    return PanelSection(
      title: l10n.overviewPressureTitle,
      children: [
        // A container without its own pressure files withholds them all:
        // the reason then stands alone, without a caption over nothing.
        if (figures.isNotEmpty) ...[
          Text(
            l10n.overviewPressureCaption,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          _Facts(stale: stale, facts: figures),
        ] else if (withheld == null)
          Text(l10n.overviewPressureNone, style: _valueStyle(context, stale)),
        ?withheld,
      ],
    );
  }

  Widget load(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final load = core.load;
    String? figure(double? value) =>
        value == null ? null : l10n.overviewLoadValue(value);
    return PanelSection(
      title: l10n.overviewLoadTitle,
      children: [
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewLoad1, figure(load?.load1)),
            (l10n.overviewLoad5, figure(load?.load5)),
            (l10n.overviewLoad15, figure(load?.load15)),
            (l10n.overviewLoadPerCore, figure(core.loadPerCore)),
          ],
        ),
        // The averages come from /proc/loadavg; with only the per-core
        // figure withheld, they show and its core count is the host's.
        ?(_withheld(l10n, const [MetricField.load]) ??
            _withheld(l10n, const [
              MetricField.loadPerCore,
            ], text: l10n.overviewUnknownContainerLoadPerCore)),
      ],
    );
  }

  /// [value] in the chart formatters' IEC units, null when unknown.
  static String? _bytes(AppLocalizations l10n, int? value) => value == null
      ? null
      : formatChartValue(
          value.toDouble(),
          ChartUnit.bytes,
          klabautermannChartStrings(l10n),
        );

  Widget memory(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final memory = core.memory;
    String? bytes(int? value) => _bytes(l10n, value);
    return PanelSection(
      title: l10n.overviewMemoryTitle,
      children: [
        // Only used is drawn: it is the total less MemAvailable, which
        // counts no shared memory and keeps some cache back, so buffers
        // and cache overlap it and would stack past what is taken.
        ..._charts(
          context,
          series: MetricSeries.memoryUsed,
          label: l10n.overviewMemoryTitle,
          unit: ChartUnit.bytes,
          segments: [
            BarSegment(
              label: l10n.overviewMemoryUsed,
              value: memory?.usedBytes?.toDouble(),
            ),
          ],
          total: memory?.totalBytes?.toDouble(),
          thresholds: ThresholdScope.of(context, ThresholdMetric.memory),
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewMemoryTotal, bytes(memory?.totalBytes)),
            (l10n.overviewMemoryAvailable, bytes(memory?.availableBytes)),
            (l10n.overviewMemoryBuffers, bytes(memory?.buffersBytes)),
            (l10n.overviewMemoryCache, bytes(memory?.cachedBytes)),
            (l10n.overviewMemoryShared, bytes(memory?.sharedBytes)),
          ],
        ),
        if (memory?.zfsArcCountedAsUsed ?? false)
          PanelNotice(icon: Icons.info_outline, text: l10n.overviewMemoryArc),
        ?_withheld(l10n, const [MetricField.memory]),
      ],
    );
  }

  /// NET-01's total rates over every interface the host reported; the
  /// first reading after a start or a counter reset has none.
  Widget network(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final totals = networkTotals(core.network);
    String? rate(double? value) => value == null
        ? null
        : formatChartValue(value, ChartUnit.bytesPerSecond, strings);
    return PanelSection(
      title: l10n.systemNetworkTitle,
      children: [
        _Facts(
          stale: stale,
          facts: [
            (l10n.systemReceive, rate(totals?.rx)),
            (l10n.systemTransmit, rate(totals?.tx)),
          ],
        ),
      ],
    );
  }

  Widget swap(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final memory = core.memory;
    final total = memory?.swapTotalBytes;
    return PanelSection(
      title: l10n.overviewSwapTitle,
      children: [
        if (total == 0)
          Text(l10n.overviewSwapNone, style: _valueStyle(context, stale))
        else ...[
          ..._charts(
            context,
            series: MetricSeries.swapUsed,
            label: l10n.overviewSwapTitle,
            unit: ChartUnit.bytes,
            segments: [
              BarSegment(
                label: l10n.overviewMemoryUsed,
                value: memory?.swapUsedBytes?.toDouble(),
              ),
            ],
            total: total?.toDouble(),
          ),
          _Facts(
            stale: stale,
            facts: [(l10n.overviewMemoryTotal, _bytes(l10n, total))],
          ),
        ],
        ?_withheld(l10n, const [MetricField.memory]),
      ],
    );
  }
}

/// Each core's busy share as a bar beside its name and figure, read as
/// "cpu0 12%"; they wrap into as many columns as the card holds.
class _CoreBars extends StatelessWidget {
  const _CoreBars({required this.cores, required this.stale});

  final List<(String, double)> cores;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strings = klabautermannChartStrings(l10n);
    final scaler = MediaQuery.textScalerOf(context);
    final style = _valueStyle(context, stale);
    // Every name gets the longest one's width on one line, so `cpu100`
    // does not wrap into what reads as a lower core and the bars line up.
    // Measured in the style `Text` resolves, bold text included.
    var nameStyle = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      nameStyle = nameStyle.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: nameStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width.ceilToDouble();
    }

    final nameWidth = cores.fold(
      0.0,
      (widest, core) => math.max(
        widest,
        math.min(measure(core.$1), scaler.scale(_coreNameMaxWidth)),
      ),
    );
    // Every figure gets the widest one's room, so its digits take none of
    // its bar's length and the bars compare across cores. That room comes
    // out of the bar, not the row, so the boxes cost no column of cores on
    // a narrow phone.
    final figureWidth = measure(
      formatChartValue(100, ChartUnit.percent, strings),
    );
    return Wrap(
      spacing: _gap,
      runSpacing: 8,
      children: [
        for (final (name, value) in cores)
          SizedBox(
            width: nameWidth + _coreGap + scaler.scale(_coreBarAndFigureWidth),
            child: MergeSemantics(
              child: Row(
                spacing: _coreGap,
                children: [
                  SizedBox(
                    width: nameWidth,
                    child: Text(
                      name,
                      style: style,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: ExcludeSemantics(
                      child: StackedBar(
                        label: name,
                        segments: [
                          BarSegment(label: l10n.overviewCpuBusy, value: value),
                        ],
                        total: 100,
                        unit: ChartUnit.percent,
                        strings: strings,
                        stale: stale,
                        showLegend: false,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: figureWidth,
                    child: Text(
                      formatChartValue(value, ChartUnit.percent, strings),
                      style: style,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Value text, grey while stale (03 §9.5 item 4), in tabular figures.
TextStyle? _valueStyle(BuildContext context, bool stale) {
  final theme = Theme.of(context);
  return theme.textTheme.bodyMedium?.copyWith(
    color: stale ? theme.colorScheme.onSurfaceVariant : null,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Labelled figures side by side, wrapping at large text, each read as one
/// node. Null reads "Unknown", never zero (03 §10.4), as do no facts at
/// all.
class _Facts extends StatelessWidget {
  const _Facts({required this.stale, required this.facts});

  final bool stale;
  final List<(String, String?)> facts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = _valueStyle(context, stale);
    if (facts.isEmpty) return Text(l10n.overviewUnknown, style: style);

    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(value ?? l10n.overviewUnknown, style: style),
              ],
            ),
          ),
      ],
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/docker_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/overview_layout.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'cpu_hints.dart';
import 'doctor.dart';
import 'docker/containers_view.dart' show containerNameOf;
import 'failed_units_summary.dart';
import 'fleet_row_state.dart' show kFleetRowStaleAfter;
import 'freshness.dart';
import 'overview_cards.dart';
import 'history_card.dart';
import 'panel_kit.dart';
import 'quick_actions.dart';
import 'slowness.dart';
import 'system_view.dart';
import 'threshold_announcer.dart';
import 'threshold_scope.dart';
import 'time_display.dart';
import 'top_lists.dart';

part 'overview_core_cards.dart';
part 'overview_docker_card.dart';
part 'overview_health.dart';
part 'overview_host_disks.dart';

const double _gap = 16;

/// The limit for the slow streams the health and Disks cards read (03
/// §6.4): `fs` every 30 to 120 s and `failedUnits` every 60 s, so the
/// fleet rows' `fs` limit, twice the slowest, judges both.
final Duration _slowStaleAfter = kFleetRowStaleAfter[SampleStream.fs]!;

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
    this.statusCard,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Whether the panel's tab shows; see [SampledSurface.visible].
  final bool visible;

  /// The server's coverage card (03 §9.5 item 3), under the cards at the
  /// full width; the workspace and the phone's screen compose it.
  final Widget? coverage;

  /// The way to the server's status card (PLT-08), last; the workspace
  /// and the phone's screen compose it with the server's name.
  final Widget? statusCard;

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
                : kSilentListenable,
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
      serverId: serverId,
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
        final wide = panelIsWide(context, box);
        final layout =
            OverviewLayoutScope.maybeOf(context)?.value ??
            OverviewLayout.standard;
        return SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: _gap,
            children: [
              // The live stream's line heads the panel: a pause or a lost
              // link holds every card, and the slow cards add their age.
              if (head != null)
                PanelNotice(
                  icon: head.stale ? Icons.history : Icons.schedule,
                  text: freshnessText(l10n, head),
                ),
              partTwo.health(
                context,
                scope,
                onDoctor: () => showDoctor(
                  context,
                  monitoring: monitoring,
                  serverId: serverId,
                ),
              ),
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
              // OV-06: the cards in this device's order, those a server
              // cannot show left out.
              ...arrangedOverviewCards(
                layout.shown,
                wide: wide,
                gap: _gap,
                card: (card) => switch (card) {
                  // OV-08, where this device has anything to offer.
                  OverviewCard.quickActions
                      when quickActionsShown(context, serverId) =>
                    QuickActionsCard(serverId: serverId),
                  OverviewCard.quickActions => null,
                  OverviewCard.cpu => cards?.cpu(context),
                  OverviewCard.load => cards?.load(context),
                  OverviewCard.memory => cards?.memory(context),
                  OverviewCard.swap => cards?.swap(context),
                  OverviewCard.pressure => cards?.pressure(context),
                  OverviewCard.disks => partTwo.disks(context),
                  OverviewCard.network => cards?.network(context),
                  OverviewCard.host => partTwo.host(context),
                  OverviewCard.docker =>
                    docker.shown
                        ? _DockerCard(
                            docker: docker,
                            controller: monitoring.docker,
                            serverId: serverId,
                          )
                        : null,
                  // OV-07: what keeps the server busy, read while this shows.
                  OverviewCard.topLists => TopListsCard(
                    monitoring: monitoring,
                    serverId: serverId,
                    visible: visible,
                  ),
                  OverviewCard.history => HistoryCard(
                    reads: monitoring.rollups,
                    serverId: serverId,
                  ),
                },
              ),
              ?coverage,
              ?statusCard,
              if (OverviewLayoutScope.maybeOf(context) case final controller?)
                EditOverviewCardsButton(layout: controller),
            ],
          ),
        );
      },
    );
  }
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

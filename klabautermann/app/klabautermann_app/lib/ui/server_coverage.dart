import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'coverage.dart' show CoverageItem, CoverageTierBadge, pausesInBackground;
import 'fleet_row_state.dart' show kFleetRowStaleAfter;
import 'freshness.dart';
import 'time_display.dart';
import 'server_surfaces.dart' show SampledSurface;
import 'system_panel.dart' show PanelNotice, PanelSection;

/// The window of the session chart, as long as the session rings hold at
/// the Desktop `core` cadence (OV-03).
const Duration _sessionSpan = Duration(minutes: 10);

/// The session chart's height before text scaling.
const double _sessionChartHeight = 160;

/// The most of the screen's height a [NoticeBanner] takes.
const double _bannerMaxShare = 0.2;

/// The most gaps the inspector lists, newest first, counting the rest: a
/// collector failing every other reading would otherwise fill it with
/// lines and push what is not covered out of sight.
const int _listedGaps = 5;

/// The subscription surface of the card's one `units` read (D45).
const String _unitsSurface = 'coverage';

/// What a server's coverage says about external monitors (03 §9.5 item
/// 3): K04's rule over the latest `units` list this engine run, or why it
/// cannot tell. The units are server data and are never translated.
(IconData, String) externalMonitorLine(
  AppLocalizations l10n, {
  required Sample? latest,
  required Sample? reading,
}) {
  final report = switch (reading?.result) {
    final UnitsResult units => externalMonitorsIn(units),
    _ => null,
  };
  String names({required bool running}) => [
    for (final unit in report!.units)
      if (unit.running == running) unit.unit,
  ].join(l10n.chartListSeparator);
  return switch (report?.status) {
    AccessStatus.ok => (
      Icons.visibility_outlined,
      l10n.coverageMonitorRunning(names(running: true)),
    ),
    AccessStatus.missing when report!.units.isNotEmpty => (
      Icons.remove_circle_outline,
      l10n.coverageMonitorStopped(names(running: false)),
    ),
    AccessStatus.missing => (
      Icons.remove_circle_outline,
      l10n.coverageMonitorNone,
    ),
    null when latest?.result is! CollectorUnavailable => (
      Icons.hourglass_empty,
      l10n.coverageMonitorChecking,
    ),
    _ => (Icons.help_outline, l10n.coverageMonitorUnknown),
  };
}

/// 03 §9.5 item 3 on a server's Overview: the T0 badge with the live
/// readings this device takes, the session chart with its gaps labelled
/// (item 5), any external monitor on the host and what is not covered.
/// No control offers T1 or T2, which do not exist yet.
///
/// The external-monitor rule reads a `units` list. While [visible], and
/// until one arrives this engine run, the card subscribes `units` itself,
/// so the Overview reads the list once rather than at the Services tab's
/// cadence; a list the Services tab reads later updates it.
class ServerCoverageCard extends StatelessWidget {
  const ServerCoverageCard({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Whether the Overview shows; the clock and the `units` read follow it.
  final bool visible;

  /// What the chart listens to instead of the clock while nothing in it
  /// ages or it hides.
  static final Listenable _silent = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final latest = monitoring.sampleFor(serverId, SampleStream.units);
    final reading = monitoring.lastReadingFor(serverId, SampleStream.units);
    final sampling = monitoring.samplingFor(serverId);
    final history = monitoring.historyFor(serverId, MetricSeries.cpuBusy);
    return ListenableBuilder(
      listenable: Listenable.merge([latest, reading, sampling]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final (icon, monitor) = externalMonitorLine(
          l10n,
          latest: latest.value,
          reading: reading.value,
        );
        return SampledSurface(
          monitoring: monitoring,
          serverId: serverId,
          surface: _unitsSurface,
          streams: const {SampleStream.units},
          visible: visible && latest.value == null,
          child: PanelSection(
            title: l10n.coverageServerTitle,
            children: [
              _TierLine(sampling: sampling.value),
              // The ring's first reading or gap starts the clock: before
              // it, nothing in the chart moves with time.
              ListenableBuilder(
                listenable: history,
                builder: (context, _) => ListenableBuilder(
                  listenable:
                      visible && (history.length > 0 || history.gaps.isNotEmpty)
                      ? monitoring.clock
                      : _silent,
                  builder: (context, _) => _SessionChart(
                    serverId: serverId,
                    history: history,
                    end: monitoring.clock.value,
                  ),
                ),
              ),
              PanelNotice(icon: icon, text: monitor),
              _NotCovered(detailed: false),
            ],
          ),
        );
      },
    );
  }
}

/// The desktop inspector's coverage of the selected server (03 §10.2's
/// Coverage section, §9.5 item 3): the T0 badge with the live readings
/// and their freshness, the session's recent gaps in words, any external
/// monitor and what is not covered, each with why. It reads what the
/// panels sample and subscribes nothing itself.
class ServerCoverageDetails extends StatelessWidget {
  const ServerCoverageDetails({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final core = monitoring.lastReadingFor(serverId, SampleStream.core);
    final latest = monitoring.sampleFor(serverId, SampleStream.units);
    final reading = monitoring.lastReadingFor(serverId, SampleStream.units);
    final sampling = monitoring.samplingFor(serverId);
    final history = monitoring.historyFor(serverId, MetricSeries.cpuBusy);
    return ListenableBuilder(
      listenable: Listenable.merge([core, latest, reading, sampling, history]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final strings = klabautermannChartStrings(l10n);
        final (icon, monitor) = externalMonitorLine(
          l10n,
          latest: latest.value,
          reading: reading.value,
        );
        Widget heading(String text) => Semantics(
          header: true,
          child: Text(text, style: theme.textTheme.titleSmall),
        );
        return ListView(
          children: [
            heading(l10n.coverageServerTitle),
            const SizedBox(height: 8),
            _TierLine(sampling: sampling.value),
            const SizedBox(height: 8),
            // As on the Overview: before a reading only a pause has news.
            if (core.value != null ||
                sampling.value?.state.phase ==
                    SamplingPhase.pausedInBackground) ...[
              _FreshnessLine(
                monitoring: monitoring,
                reading: core.value,
                sampling: sampling.value,
              ),
              const SizedBox(height: 8),
            ],
            PanelNotice(icon: icon, text: monitor),
            const SizedBox(height: 16),
            heading(l10n.coverageDetailsGaps),
            const SizedBox(height: 8),
            // No gap in a record without readings is not news.
            if (history.length == 0 && history.gaps.isEmpty)
              Text(l10n.coverageFreshnessNoData)
            else if (history.gaps.isEmpty)
              Text(l10n.coverageDetailsNoGaps)
            else ...[
              for (final gap in history.gaps.reversed.take(_listedGaps))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(chartGapText(gap, strings)),
                ),
              if (history.gaps.length > _listedGaps)
                Text(
                  l10n.coverageDetailsEarlierGaps(
                    history.gaps.length - _listedGaps,
                  ),
                ),
            ],
            const SizedBox(height: 16),
            _NotCovered(detailed: true),
          ],
        );
      },
    );
  }
}

/// 03 §9.5 item 6 on an iOS or Android server screen or workspace: after
/// a return from the background that paused this server's readings, when
/// it was paused and that the charts have no data for it, until
/// dismissed. A desktop platform never reports the background, so it
/// never shows there.
class BackgroundReturnBanner extends StatelessWidget {
  const BackgroundReturnBanner({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: monitoring.backgroundPause,
      builder: (context, pause, _) {
        if (pause == null || !pause.serverIds.contains(serverId)) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        // To the minute, unless that would read as no time at all.
        var start = l10n.chartTime(pause.start);
        var end = l10n.chartTime(pause.end);
        if (start == end) {
          start = l10n.chartTimeWithSeconds(pause.start);
          end = l10n.chartTimeWithSeconds(pause.end);
        }
        return NoticeBanner(
          icon: Icons.pause_circle_outline,
          text: l10n.coverageReturnBanner(start, end),
          dismissLabel: l10n.coverageReturnDismiss,
          onDismiss: monitoring.dismissBackgroundPause,
        );
      },
    );
  }
}

/// A banner over a screen's body that tells of a change until dismissed,
/// as the return banner does (03 §9.5 item 6). Its words are a state
/// change, which screen readers hear (A11Y-15).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.icon,
    required this.text,
    required this.dismissLabel,
    required this.onDismiss,
  });

  final IconData icon;
  final String text;
  final String dismissLabel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.secondaryContainer,
      // Past its share of the screen it scrolls, so at large text the
      // panel under it keeps its room on a short screen (A11Y-09).
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * _bannerMaxShare,
        ),
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
          child: Row(
            spacing: 12,
            children: [
              Icon(icon, color: colors.onSecondaryContainer),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              TextButton(onPressed: onDismiss, child: Text(dismissLabel)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The `core` stream's freshness (03 §9.5 item 4). Only a reading's age
/// moves with time, so it follows the clock only once there is one; a
/// pause has no age.
class _FreshnessLine extends StatelessWidget {
  const _FreshnessLine({
    required this.monitoring,
    required this.reading,
    required this.sampling,
  });

  final MonitoringController monitoring;
  final Sample? reading;
  final SamplingStatus? sampling;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: reading == null ? ServerCoverageCard._silent : monitoring.clock,
    builder: (context, _) {
      final freshness = freshnessOf(
        now: monitoring.clock.value,
        staleAfter: kFleetRowStaleAfter[SampleStream.core]!,
        lastSampleAt: reading?.at,
        // The monitor set changes nothing here: the engine samples a
        // monitored server's `overview`, so its phase already says that
        // something samples it (FL-21).
        watched: false,
        sampling: sampling,
      );
      return PanelNotice(
        icon: freshness.stale ? Icons.history : Icons.schedule,
        text: freshnessText(AppLocalizations.of(context), freshness),
      );
    },
  );
}

/// The T0 badge beside what the tier means and what live reading is doing
/// now, read as one node.
class _TierLine extends StatelessWidget {
  const _TierLine({required this.sampling});

  /// Before the engine says anything, the line states the tier's rule.
  final SamplingStatus? sampling;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CoverageItem(
      leading: const CoverageTierBadge(),
      title: l10n.coverageTierTitle,
      body: switch (sampling?.state.phase) {
        SamplingPhase.sampling => l10n.coverageLiveSampling,
        SamplingPhase.waitingForLink => l10n.coverageLiveWaiting,
        SamplingPhase.pausedInBackground => l10n.coverageLivePaused,
        SamplingPhase.unsubscribed => l10n.coverageLiveIdle,
        null => l10n.coverageLivePolicy,
      },
    );
  }
}

/// The session chart of CPU busy on a time axis: a hatched band labels
/// each gap with why it has no data (03 §9.5 item 5), and the legend names
/// the source.
class _SessionChart extends StatelessWidget {
  const _SessionChart({
    required this.serverId,
    required this.history,
    required this.end,
  });

  final String serverId;
  final TimeSeriesRing history;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.coverageSessionTitle(_sessionSpan.inMinutes),
            style: theme.textTheme.labelLarge,
          ),
        ),
        SizedBox(
          height: MediaQuery.textScalerOf(context).scale(_sessionChartHeight),
          child: TimeSeriesChart(
            data: history,
            labels: [l10n.coverageSessionLane],
            unit: ChartUnit.percent,
            strings: klabautermannChartStrings(l10n),
            source: l10n.coverageSessionSource,
            end: end,
            span: _sessionSpan,
            max: 100,
            zoneOffset: TimeDisplayScope.serverOffsetOf(context, serverId),
          ),
        ),
      ],
    );
  }
}

/// What a server's coverage leaves out (03 §9.5 item 3), in the coverage
/// sheet's words: [detailed] adds each one's reason.
class _NotCovered extends StatelessWidget {
  const _NotCovered({required this.detailed});

  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // The heading says not covered in words; the icon's shape differs
    // from the covered one's (10.10: never colour alone).
    final icon = Icon(
      Icons.remove_circle_outline,
      size: 20,
      color: theme.colorScheme.onSurfaceVariant,
    );
    CoverageItem item(String title, String body) =>
        CoverageItem(leading: icon, title: title, body: detailed ? body : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.coverageNotCoveredHeading,
            style: theme.textTheme.labelLarge,
          ),
        ),
        item(l10n.coverageClosedTitle, l10n.coverageClosedBody),
        item(l10n.coverageHostDownTitle, l10n.coverageHostDownBody),
        item(l10n.coverageHistoryTitle, l10n.coverageHistoryBody),
        if (pausesInBackground(context))
          item(l10n.coverageBackgroundTitle, l10n.coverageBackgroundBody),
      ],
    );
  }
}

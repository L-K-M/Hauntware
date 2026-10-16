import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'fleet_row_state.dart' show kFleetRowStaleAfter, kFleetRowThresholds;
import 'freshness.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

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

/// The Overview tab, part one (03 §10.4; OV-01, OV-03, OV-04): CPU in
/// total and per core (CPU-01, CPU-02), load with core context (CPU-03),
/// memory with the ZFS ARC note (MEM-01) and swap (MEM-02), with session
/// sparklines from the controller's rings and bar gauges.
///
/// It shows the last reading of the `core` stream its [SampledSurface]
/// subscribes under one freshness line in 9.5 item 4's words, and greys
/// the values once that line says stale. A failed reading says why above
/// them. Figures go through the chart formatters' IEC units (A11Y-06);
/// what the host did not report reads "Unknown" or is hatched, and a
/// figure a container withholds (D50) says so. The clock ticks only while
/// [visible].
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
    return ListenableBuilder(
      listenable: Listenable.merge([latest, reading, sampling]),
      builder: (context, _) => ListenableBuilder(
        listenable: visible && reading.value != null
            ? monitoring.clock
            : _silent,
        builder: (context, _) =>
            _build(context, latest.value, reading.value, sampling.value),
      ),
    );
  }

  Widget _build(
    BuildContext context,
    Sample? latest,
    Sample? reading,
    SamplingStatus? sampling,
  ) {
    final l10n = AppLocalizations.of(context);
    final freshness = freshnessOf(
      now: monitoring.clock.value,
      staleAfter: kFleetRowStaleAfter[SampleStream.core]!,
      lastSampleAt: reading?.at,
      // No monitor set watches a server yet (FL-21): this panel samples it
      // while it shows.
      watched: false,
      sampling: sampling,
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
        stale: freshness.stale,
      ),
      _ => null,
    };

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        Widget column(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: _gap,
          children: children,
        );
        return SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: column([
            if (reading != null || freshness is FreshnessPaused)
              PanelNotice(
                icon: freshness.stale ? Icons.history : Icons.schedule,
                text: freshnessText(l10n, freshness),
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
            if (cards != null && wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: _gap,
                children: [
                  Expanded(
                    child: column([cards.cpu(context), cards.load(context)]),
                  ),
                  Expanded(
                    child: column([cards.memory(context), cards.swap(context)]),
                  ),
                ],
              )
            else if (cards != null) ...[
              cards.cpu(context),
              cards.load(context),
              cards.memory(context),
              cards.swap(context),
            ],
            ?coverage,
          ]),
        );
      },
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
          thresholds: kFleetRowThresholds,
        ),
        _Facts(
          stale: stale,
          facts: [
            (l10n.overviewCpuUser, percent(cpu?.user)),
            (l10n.overviewCpuSystem, percent(cpu?.system)),
            (l10n.overviewCpuIdle, percent(cpu?.idle)),
          ],
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
          thresholds: kFleetRowThresholds,
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

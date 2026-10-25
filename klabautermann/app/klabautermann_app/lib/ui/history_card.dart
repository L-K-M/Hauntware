import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/history_reads.dart';
import '../l10n/app_localizations.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// The metrics the History card offers: the percentages it charts on one
/// scale from zero to 100. Load per core has no such ceiling, so the card
/// leaves it out.
const historyMetrics = [
  AlertMetric.cpuBusy,
  AlertMetric.memoryUsed,
  AlertMetric.diskUsed,
  AlertMetric.diskInodes,
];

/// [range]'s [metric] in [tier] as a chart's ring (03 §7.20, Y4): a tick
/// per bucket with its mean and its peak, and a gap wherever buckets
/// stop. A gap takes the cause the engine recorded over it; one without
/// is time the app was closed or did not sample the server. A run that
/// ends before [now] leaves its gap open to the chart's edge.
TimeSeriesRing historyRing(
  HistoryRange range,
  HistoryTier tier,
  AlertMetric metric, {
  required DateTime now,
}) {
  final ring = TimeSeriesRing(capacity: tier.slots + 1, lanes: 2);
  final width = tier.bucket;
  DateTime? lastEnd;
  void openGapAt(DateTime from, DateTime until) => ring.openGap(
    from,
    _gapReason(range.gaps, from, until) ?? ChartGapReason.appClosed,
  );

  for (final bucket in range.buckets) {
    final stat = bucket.values[metric];
    final end = lastEnd;
    if (end != null && bucket.start.isAfter(end)) {
      openGapAt(end, bucket.start);
    }
    // A tick sits at its bucket's middle, as its readings spread across it.
    ring.add(bucket.start.add(width ~/ 2), [stat?.mean, stat?.max]);
    lastEnd = bucket.start.add(width);
  }
  final end = lastEnd;
  if (end != null && now.isAfter(end.add(width))) openGapAt(end, now);
  return ring;
}

/// The cause the engine recorded for most of [from] to [until], or null
/// when it recorded none there.
ChartGapReason? _gapReason(
  List<HistoryGap> gaps,
  DateTime from,
  DateTime until,
) {
  HistoryGap? best;
  var bestOverlap = Duration.zero;
  for (final gap in gaps) {
    final start = gap.from.isAfter(from) ? gap.from : from;
    final stop = gap.until.isBefore(until) ? gap.until : until;
    final overlap = stop.difference(start);
    if (overlap > bestOverlap) {
      best = gap;
      bestOverlap = overlap;
    }
  }
  return switch (best?.cause) {
    GapCause.background => ChartGapReason.background,
    GapCause.disconnected => ChartGapReason.disconnected,
    GapCause.readingLost => ChartGapReason.readingFailed,
    null => null,
  };
}

/// The Overview's History card (HIS-01, 03 §7.20): a metric's rolled-up
/// mean and peak over 48 hours or 30 days, with every gap a labelled band,
/// from what this device recorded while Klabautermann was open. It reads
/// when it first shows, when the user picks another tier or metric, and
/// on refresh.
class HistoryCard extends StatefulWidget {
  const HistoryCard({
    super.key,
    required this.reads,
    required this.serverId,
    this.now = DateTime.now,
  });

  final HistoryReads reads;
  final String serverId;

  /// The chart's right edge when it reads; the wall clock outside tests.
  final DateTime Function() now;

  @override
  State<HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<HistoryCard> {
  static const _chartHeight = 200.0;

  HistoryTier _tier = HistoryTier.minute;
  AlertMetric _metric = AlertMetric.cpuBusy;
  HistoryRange? _range;
  DateTime? _readAt;
  int _reading = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(HistoryCard old) {
    super.didUpdateWidget(old);
    if (old.serverId != widget.serverId || old.reads != widget.reads) {
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    final ticket = ++_reading;
    final range = await widget.reads.read(widget.serverId, _tier);
    // Only the newest read lands, so a slow answer for another tier or
    // server never replaces a later one.
    if (!mounted || ticket != _reading) return;
    setState(() {
      _range = range;
      _readAt = widget.now().toUtc();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final range = _range;
    final readAt = _readAt;
    final empty = range != null && range.buckets.isEmpty;
    return PanelSection(
      title: l10n.historyTitle,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Chips rather than a segmented button or a menu, so each
            // wraps on its own at large text sizes.
            for (final (tier, label) in [
              (HistoryTier.minute, l10n.historyLastHours(48)),
              (HistoryTier.tenMinutes, l10n.historyLastDays(30)),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _tier == tier,
                showCheckmark: false,
                onSelected: (_) {
                  if (_tier == tier) return;
                  setState(() => _tier = tier);
                  unawaited(_read());
                },
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.historyRefresh,
              onPressed: () => unawaited(_read()),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final metric in historyMetrics)
              ChoiceChip(
                label: Text(historyMetricName(l10n, metric)),
                selected: _metric == metric,
                showCheckmark: false,
                onSelected: (_) => setState(() => _metric = metric),
              ),
          ],
        ),
        if (empty)
          PanelNotice(icon: Icons.history, text: l10n.historyEmpty)
        else if (range != null && readAt != null)
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(_chartHeight),
            child: TimeSeriesChart(
              data: historyRing(range, _tier, _metric, now: readAt),
              labels: [l10n.historyLaneMean, l10n.historyLanePeak],
              unit: ChartUnit.percent,
              strings: klabautermannChartStrings(l10n),
              source: l10n.historySource,
              end: readAt,
              span: _tier.span,
              max: 100,
            ),
          ),
      ],
    );
  }
}

/// The words for a History metric.
String historyMetricName(AppLocalizations l10n, AlertMetric metric) =>
    switch (metric) {
      AlertMetric.cpuBusy => l10n.historyMetricCpu,
      AlertMetric.memoryUsed => l10n.historyMetricMemory,
      AlertMetric.diskUsed => l10n.historyMetricDisk,
      AlertMetric.diskInodes => l10n.historyMetricInodes,
      AlertMetric.loadPerCore => l10n.historyMetricLoad,
    };

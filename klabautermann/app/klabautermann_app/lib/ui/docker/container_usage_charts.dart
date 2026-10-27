import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;

import '../../controllers/container_usage.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../chart_strings.dart';
import '../charts/charts.dart';

/// How much time each chart shows: what the history keeps.
const _span = Duration(minutes: 30);

/// One chart's height at a text scale of 1.
const double _chartHeight = 120;

/// A running container's usage since this device began reading its stats
/// (CST-03): CPU, memory against its limit, network and block I/O rates
/// and PIDs, one chart each, from the list stats the container watch
/// reads every 5 s while its details show. Memory at or above
/// [kMemoryRiskShare] of the limit says so in words beside an icon
/// (CST-04).
class ContainerUsageCharts extends StatelessWidget {
  const ContainerUsageCharts({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.containerId,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String containerId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final usage = monitoring.docker.usageFor(serverId, containerId);
    return ListenableBuilder(
      listenable: Listenable.merge([monitoring.clock, usage.memory]),
      builder: (context, _) {
        final end = monitoring.clock.value;
        final latest = usage.latest;
        final share = latest == null ? null : memoryLimitShare(latest);
        final strings = klabautermannChartStrings(l10n);
        final source = l10n.dockerUsageSource;
        Widget chart(
          String title,
          TimeSeriesRing data,
          List<String> labels,
          ChartUnit unit,
        ) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Text(title, style: theme.textTheme.labelLarge),
            SizedBox(
              height: MediaQuery.textScalerOf(context).scale(_chartHeight),
              child: TimeSeriesChart(
                data: data,
                labels: labels,
                unit: unit,
                strings: strings,
                source: source,
                end: end,
                span: _span,
              ),
            ),
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.dockerUsageTitle,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (latest == null)
              Text(
                l10n.dockerUsageWaiting,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (share != null && share >= kMemoryRiskShare)
              MergeSemantics(
                child: Row(
                  spacing: 8,
                  children: [
                    Icon(
                      Icons.warning_amber,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    Expanded(
                      child: Text(
                        l10n.dockerUsageMemoryRisk(
                          share,
                          ghostFormatBinarySize(latest!.memoryUsed!),
                          ghostFormatBinarySize(latest.memoryLimit!),
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            chart(l10n.dockerUsageCpu, usage.cpu, [
              l10n.dockerUsageCpu,
            ], ChartUnit.percent),
            chart(l10n.dockerUsageMemory, usage.memory, [
              l10n.dockerUsageMemoryUsed,
              l10n.dockerUsageMemoryLimit,
            ], ChartUnit.bytes),
            chart(l10n.dockerUsageNetwork, usage.network, [
              l10n.dockerUsageNetworkIn,
              l10n.dockerUsageNetworkOut,
            ], ChartUnit.bytesPerSecond),
            chart(l10n.dockerUsageBlockIo, usage.blockIo, [
              l10n.dockerUsageBlockRead,
              l10n.dockerUsageBlockWrite,
            ], ChartUnit.bytesPerSecond),
            chart(l10n.dockerUsagePids, usage.pids, [
              l10n.dockerUsagePids,
            ], ChartUnit.count),
          ],
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_row_state.dart' show ghostSessionOf;
import 'fleet_triage.dart';

/// FL-09's strip over the fleet list: how many servers answer, how many
/// need attention, and the CPU and memory of those reporting fresh
/// readings. [openProblems] is the attention queue's open problems by
/// server. One screen-reader node, read as a sentence.
class FleetSummaryStrip extends StatelessWidget {
  const FleetSummaryStrip({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.openProblems,
    this.now = DateTime.now,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final Map<String, int> openProblems;

  /// The clock the readings' freshness is judged by.
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final servers = fleet.servers;
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final overview = {
      for (final server in servers)
        server.id: monitoring.sampleFor(server.id, SampleStream.overview),
    };
    final core = {
      for (final server in servers)
        server.id: monitoring.sampleFor(server.id, SampleStream.core),
    };
    return ListenableBuilder(
      listenable: Listenable.merge([...overview.values, ...core.values]),
      builder: (context, _) {
        final summary = fleetSummary(
          servers: servers,
          session: (id) => ghostSessionOf(fleet.linkStatusFor(id)),
          probe: fleet.reachabilityFor,
          overview: (id) => overview[id]?.value,
          core: (id) => core[id]?.value,
          openProblems: openProblems,
          now: now(),
        );
        final l10n = AppLocalizations.of(context);
        final theme = Theme.of(context);
        final parts = [
          l10n.fleetSummaryOnline(summary.online, summary.total),
          if (summary.needAttention > 0)
            l10n.fleetSummaryAttention(summary.needAttention),
          if (summary.cpuPercent case final cpu?)
            l10n.fleetSummaryCpu(cpu.round()),
          if ((summary.memoryUsedBytes, summary.memoryTotalBytes) case (
            final used?,
            final total?,
          ))
            l10n.fleetSummaryMemory(
              ghostFormatBinarySize(used),
              ghostFormatBinarySize(total),
            ),
        ];
        return MergeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 2),
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                for (final part in parts)
                  Text(
                    part,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

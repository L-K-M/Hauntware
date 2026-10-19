import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'docker/container_details.dart';
import 'server_coverage.dart';

/// The desktop inspector of 03 §10.2: Details, Alerts (v1), Operations,
/// Coverage and Audit sections, empty until a server is selected. The
/// selected server's coverage (03 §9.5 item 3) is the first to land; a
/// container its Containers sub-tab opens shows in its place until
/// closed or another server is selected (03 §7.12 CTR-03,
/// [ContainerInspectionScope]).
class InspectorPane extends StatelessWidget {
  const InspectorPane({
    super.key,
    required this.fleet,
    required this.monitoring,
  });

  final FleetController fleet;

  /// What the selected server's coverage reads.
  final MonitoringController monitoring;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final inspection = ContainerInspectionScope.maybeOf(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.inspectorTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            // The inspector fills in as link statuses and operations arrive;
            // it listens for its own concern only (03 §10.1).
            Expanded(
              child: ListenableBuilder(
                listenable: fleet,
                builder: (context, _) =>
                    switch ((fleet.selectedServer?.id, inspection?.value)) {
                      // The shell lets another server's container go.
                      (final serverId?, final inspected?)
                          when inspected.serverId == serverId =>
                        ContainerInspectorBody(
                          // A new container's details start at their top.
                          key: ValueKey(inspected.container.id),
                          monitoring: monitoring,
                          inspected: inspected,
                          onClose: () => inspection?.value = null,
                        ),
                      (final serverId?, _) => ServerCoverageDetails(
                        // A new server's details start at their top.
                        key: ValueKey(serverId),
                        monitoring: monitoring,
                        serverId: serverId,
                      ),
                      (null, _) => const InspectorEmptyBody(),
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inspector's empty body, also the panels' placeholder until their
/// subsystems land.
class InspectorEmptyBody extends StatelessWidget {
  const InspectorEmptyBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Text(
      l10n.inspectorEmptyBody,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// The generic placeholder for surfaces whose milestone has not landed.
class PlaceholderPaneBody extends StatelessWidget {
  const PlaceholderPaneBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        l10n.placeholderMilestone,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

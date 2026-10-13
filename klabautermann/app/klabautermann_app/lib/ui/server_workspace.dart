import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rail.dart' show linkPhaseWord;
import 'inspector_pane.dart' show PlaceholderPaneBody;

/// The server workspace of 03 §10.2: a header over the panel tab strip.
/// The panels themselves land with their subsystems (F4 onward); each tab
/// already sits in its planned order so the strip's shape is final.
class ServerWorkspace extends StatelessWidget {
  const ServerWorkspace({
    super.key,
    required this.fleet,
    required this.monitoring,
  });

  final FleetController fleet;

  /// Per-server sample listenables feed the panels through this (03
  /// §10.1); the placeholder body keeps the seam already.
  final MonitoringController monitoring;

  static List<String> _tabLabels(AppLocalizations l10n) => [
    l10n.workspaceTabOverview,
    l10n.workspaceTabProcesses,
    l10n.workspaceTabServices,
    l10n.workspaceTabLogs,
    l10n.workspaceTabJobs,
    l10n.workspaceTabDocker,
    l10n.workspaceTabSystem,
    l10n.workspaceTabAccess,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The selection and every link phase arrive through one listenable, so
    // the workspace repaints for its own concern only (03 §10.1).
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) => _build(context, l10n),
    );
  }

  Widget _build(BuildContext context, AppLocalizations l10n) {
    final server = fleet.selectedServer;
    if (server == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                l10n.workspaceEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.workspaceEmptyBody,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final tabs = _tabLabels(l10n);
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.serverTitle(server.displayName),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  linkPhaseWord(l10n, fleet.linkPhaseFor(server.id)),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          TabBar(
            isScrollable: true,
            tabs: [for (final label in tabs) Tab(text: label)],
          ),
          Expanded(
            child: TabBarView(
              children: [for (final _ in tabs) const PlaceholderPaneBody()],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rail.dart' show linkStatusWord;
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'server_surfaces.dart';
import 'services_panel.dart';

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

  /// Opens the selected server, holds the visible panel's subscription and
  /// feeds the panels' per-server sample listenables (03 §10.1).
  final MonitoringController monitoring;

  static const List<ServerPanel> _panels = ServerPanel.values;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The selection and every link status arrive through one listenable, so
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

    return DefaultTabController(
      length: _panels.length,
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
                  linkStatusWord(l10n, fleet.linkStatusFor(server.id)),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          TabBar(
            isScrollable: true,
            tabs: [for (final panel in _panels) Tab(text: panel.label(l10n))],
          ),
          Expanded(
            child: _Panels(monitoring: monitoring, serverId: server.id),
          ),
        ],
      ),
    );
  }
}

/// The selected tab's panel, swapped in place, while [serverId] is held
/// open. A panel stays built once opened, so whether it samples follows
/// the tab controller's index (03 §6.4).
class _Panels extends StatelessWidget {
  const _Panels({required this.monitoring, required this.serverId});

  final MonitoringController monitoring;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final tabs = DefaultTabController.of(context);
    return OpenServer(
      monitoring: monitoring,
      serverId: serverId,
      child: ListenableBuilder(
        listenable: tabs,
        builder: (context, _) => SelectedTabView(
          children: [
            for (final (index, panel) in ServerWorkspace._panels.indexed)
              SampledSurface(
                monitoring: monitoring,
                serverId: serverId,
                surface: panel.name,
                streams: panel.streams,
                visible: tabs.index == index,
                child: switch (panel) {
                  ServerPanel.services => ServicesPanel(
                    monitoring: monitoring,
                    serverId: serverId,
                  ),
                  _ => const PlaceholderPaneBody(),
                },
              ),
          ],
        ),
      ),
    );
  }
}

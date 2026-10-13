import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rail.dart' show linkPhaseWord;
import 'inspector_pane.dart' show PlaceholderPaneBody;

/// The pushed server screen of 03 §10.5: the server's title, its link
/// state, and the bottom bar (Overview, Docker, Logs, More). The
/// destinations' bodies land with their panels.
class ServerDetailPage extends StatefulWidget {
  const ServerDetailPage({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
  });

  final FleetServer server;
  final FleetController fleet;

  /// Per-server sample listenables feed the panels through this (03
  /// §10.1); the placeholder bodies keep the seam already.
  final MonitoringController monitoring;

  @override
  State<ServerDetailPage> createState() => _ServerDetailPageState();
}

class _ServerDetailPageState extends State<ServerDetailPage> {
  int _destination = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Link phases arrive through the fleet listenable, so the pushed screen
    // follows its own concern (03 §10.1) without the shell rebuilding.
    return ListenableBuilder(
      listenable: widget.fleet,
      builder: (context, _) => _build(context, l10n),
    );
  }

  Widget _build(BuildContext context, AppLocalizations l10n) {
    final phase = widget.fleet.linkPhaseFor(widget.server.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serverTitle(widget.server.displayName)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(linkPhaseWord(l10n, phase)),
          ),
        ),
      ),
      body: const SafeArea(child: PlaceholderPaneBody()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _destination,
        onDestinationSelected: (index) => setState(() => _destination = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.speed_outlined),
            label: l10n.workspaceTabOverview,
          ),
          NavigationDestination(
            icon: const Icon(Icons.inventory_2_outlined),
            label: l10n.workspaceTabDocker,
          ),
          NavigationDestination(
            icon: const Icon(Icons.article_outlined),
            label: l10n.workspaceTabLogs,
          ),
          NavigationDestination(
            icon: const Icon(Icons.more_horiz),
            label: l10n.serverTabMore,
          ),
        ],
      ),
    );
  }
}

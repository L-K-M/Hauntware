import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rail.dart' show linkStatusWord;
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'server_surfaces.dart';

/// The pushed server screen of 03 §10.5: the server's title, its link
/// state, and the bottom bar (Overview, Docker, Logs, More). The
/// destinations' bodies land with their panels.
///
/// The server stays open while the screen is pushed, and only the
/// selected destination's panel samples its streams (03 §6.4).
class ServerDetailPage extends StatefulWidget {
  const ServerDetailPage({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
  });

  final FleetServer server;
  final FleetController fleet;

  /// Opens the server, holds the visible panel's subscription and feeds
  /// the panels' per-server sample listenables (03 §10.1).
  final MonitoringController monitoring;

  /// The bottom bar's panels, before More.
  static const List<ServerPanel> _panels = [
    ServerPanel.overview,
    ServerPanel.docker,
    ServerPanel.logs,
  ];

  @override
  State<ServerDetailPage> createState() => _ServerDetailPageState();
}

class _ServerDetailPageState extends State<ServerDetailPage>
    with SingleTickerProviderStateMixin {
  /// The bottom bar's selection, which [SelectedTabView] shows: the panels,
  /// then More.
  late final TabController _destinations = TabController(
    length: ServerDetailPage._panels.length + 1,
    vsync: this,
  );

  @override
  void dispose() {
    _destinations.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Link statuses arrive through the fleet listenable, so the pushed screen
    // follows its own concern (03 §10.1) without the shell rebuilding; the
    // bottom bar's selection arrives through its controller.
    return OpenServer(
      monitoring: widget.monitoring,
      serverId: widget.server.id,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.fleet, _destinations]),
        builder: (context, _) => _build(context, l10n),
      ),
    );
  }

  Widget _build(BuildContext context, AppLocalizations l10n) {
    final status = widget.fleet.linkStatusFor(widget.server.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serverTitle(widget.server.displayName)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(linkStatusWord(l10n, status)),
          ),
        ),
      ),
      body: SafeArea(
        child: SelectedTabView(
          controller: _destinations,
          children: [
            for (final (index, panel) in ServerDetailPage._panels.indexed)
              SampledSurface(
                monitoring: widget.monitoring,
                serverId: widget.server.id,
                surface: panel.name,
                streams: panel.streams,
                visible: _destinations.index == index,
                child: const PlaceholderPaneBody(),
              ),
            // More: the other panels, pushed further (03 §10.5).
            const PlaceholderPaneBody(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _destinations.index,
        onDestinationSelected: (index) => _destinations.index = index,
        destinations: [
          for (final panel in ServerDetailPage._panels)
            NavigationDestination(
              icon: Icon(_destinationIcons[panel]),
              label: panel.label(l10n),
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

const Map<ServerPanel, IconData> _destinationIcons = {
  ServerPanel.overview: Icons.speed_outlined,
  ServerPanel.docker: Icons.inventory_2_outlined,
  ServerPanel.logs: Icons.article_outlined,
};

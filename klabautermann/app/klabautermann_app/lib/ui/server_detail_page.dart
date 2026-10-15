import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'access/access_panel.dart' show AccessPage;
import 'access/panel_gate.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'logs/logs_panel.dart';
import 'overview_panel.dart';
import 'server_header.dart';
import 'server_surfaces.dart';

/// The pushed server screen of 03 §10.5: the server's title, the server
/// header, and the bottom bar (Overview, Docker, Logs, More). The
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

  /// Pushes the Access tab, where a hidden panel's link leads (03 §10.4);
  /// More lists it with the other panels later (03 §10.5).
  void _openAccess() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => AccessPage(
        fleet: widget.fleet,
        monitoring: widget.monitoring,
        serverId: widget.server.id,
        serverName: widget.server.displayName,
      ),
    ),
  );

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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.serverTitle(widget.server.displayName))),
      body: _HeaderedBody(
        header: ServerHeader(
          server: widget.server,
          fleet: widget.fleet,
          monitoring: widget.monitoring,
          showTitle: false,
        ),
        child: SelectedTabView(
          controller: _destinations,
          children: [
            for (final (index, panel) in ServerDetailPage._panels.indexed)
              GatedPanel(
                monitoring: widget.monitoring,
                serverId: widget.server.id,
                panel: panel,
                onOpenAccess: _openAccess,
                child: SampledSurface(
                  monitoring: widget.monitoring,
                  serverId: widget.server.id,
                  surface: panel.name,
                  streams: panel.streams,
                  visible: _destinations.index == index,
                  child: switch (panel) {
                    ServerPanel.overview => OverviewPanel(
                      monitoring: widget.monitoring,
                      serverId: widget.server.id,
                      visible: _destinations.index == index,
                    ),
                    ServerPanel.logs => LogsPanel(
                      monitoring: widget.monitoring,
                      serverId: widget.server.id,
                      visible: _destinations.index == index,
                    ),
                    _ => const PlaceholderPaneBody(),
                  },
                ),
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

/// The safe area with [header] over [child]: the header heads the body
/// rather than the app bar's fixed-height bottom, so it grows with large
/// text instead of clipping (A11Y-09).
class _HeaderedBody extends StatelessWidget {
  const _HeaderedBody({required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: header,
        ),
        Expanded(child: child),
      ],
    ),
  );
}

const Map<ServerPanel, IconData> _destinationIcons = {
  ServerPanel.overview: Icons.speed_outlined,
  ServerPanel.docker: Icons.inventory_2_outlined,
  ServerPanel.logs: Icons.article_outlined,
};

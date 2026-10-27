import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'access/access_panel.dart' show AccessPage;
import 'access/panel_gate.dart';
import 'coverage.dart' show pausesInBackground;
import 'docker/docker_panel.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'jobs_panel.dart';
import 'logs/logs_panel.dart';
import 'overview_panel.dart';
import 'connect_rejected_banner.dart';
import 'processes_panel.dart';
import 'server_coverage.dart';
import 'status_card.dart';
import 'server_header.dart';
import 'server_surfaces.dart';
import 'services_panel.dart';
import 'system_panel.dart';

/// Why a server screen closed itself, which its route pops with for the
/// fleet list under it.
enum ServerScreenExit {
  /// Its server left the fleet (SYN-08).
  leftFleet,
}

/// Where a server screen sits, which decides who closes it when its
/// server leaves the fleet (SYN-08).
enum ServerScreenPlacement {
  /// Pushed over the phone's fleet list: it closes itself.
  pushed,

  /// The tablet split's second pane (PLT-05): the shell clears it.
  pane,
}

/// The pushed server screen of 03 §10.5: the server's title, the server
/// header, and the bottom bar (Overview, Docker, Logs, More). More lists
/// the other panels, which open full-screen.
///
/// The server stays open while the screen is pushed, and only the
/// selected destination's panel samples its streams (03 §6.4); a panel
/// that samples pulls to refresh (PLT-02). On iOS and Android the header
/// says that reading stops in the background (PLT-04). A server that
/// leaves the fleet (SYN-08) closes the screen with everything opened
/// over it, and its route pops with [ServerScreenExit.leftFleet]. In the
/// tablet split the same screen fills the second pane, and the shell
/// closes it instead.
class ServerDetailPage extends StatefulWidget {
  const ServerDetailPage({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
    this.placement = ServerScreenPlacement.pushed,
  });

  final FleetServer server;
  final FleetController fleet;
  final ServerScreenPlacement placement;

  /// Opens the server, holds the visible panel's subscription and feeds
  /// the panels' per-server sample listenables (03 §10.1).
  final MonitoringController monitoring;

  /// The bottom bar's panels, before More.
  static const List<ServerPanel> _panels = [
    ServerPanel.overview,
    ServerPanel.docker,
    ServerPanel.logs,
  ];

  /// The panels More lists, in the desktop tab strip's order.
  static const List<ServerPanel> morePanels = [
    ServerPanel.processes,
    ServerPanel.services,
    ServerPanel.jobs,
    ServerPanel.system,
    ServerPanel.access,
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

  /// Set once the screen closes because its server left the fleet.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.fleet.addListener(_onFleetChanged);
  }

  @override
  void dispose() {
    widget.fleet.removeListener(_onFleetChanged);
    _destinations.dispose();
    super.dispose();
  }

  /// SYN-08 (task #50): a server that left the fleet, removed by a sync
  /// or left out of a new import, has nothing left to show, as the
  /// desktop workspace's selection clears. The screen closes with
  /// everything it opened (More's panels, the Access tab, sheets and
  /// dialogs), back to the fleet list, which says why.
  void _onFleetChanged() {
    final serverId = widget.server.id;
    if (widget.placement == ServerScreenPlacement.pane) return;
    if (_closing || widget.fleet.servers.any((s) => s.id == serverId)) return;
    // The fleet list is the route below; a screen with none has nowhere
    // to go back to.
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive || route.isFirst) return;

    _closing = true;
    Navigator.of(context)
      ..popUntil((other) => other == route)
      ..pop(ServerScreenExit.leftFleet);
  }

  /// Pushes the Access tab, which More lists and a hidden panel's link
  /// leads to (03 §10.4).
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

  /// Opens one of More's panels full-screen (03 §10.5).
  void _openPanel(ServerPanel panel) {
    if (panel == ServerPanel.access) {
      _openAccess();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _PanelPage(
          server: widget.server,
          monitoring: widget.monitoring,
          fleet: widget.fleet,
          panel: panel,
          onOpenAccess: _openAccess,
        ),
      ),
    );
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.serverTitle(widget.server.displayName))),
      // The header heads the body rather than the app bar's fixed-height
      // bottom, so it grows with large text instead of clipping (A11Y-09).
      body: SafeArea(
        child: HeaderedBody(
          headerPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          header: ServerHeader(
            server: widget.server,
            fleet: widget.fleet,
            monitoring: widget.monitoring,
            showTitle: false,
            // PLT-04, said plainly where the platform reports the
            // background (AppActivityReporter).
            limitations: [
              if (pausesInBackground(context)) l10n.coverageBackgroundBody,
            ],
          ),
          banner: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConnectRejectedBanner(
                monitoring: widget.monitoring,
                serverId: widget.server.id,
              ),
              BackgroundReturnBanner(
                monitoring: widget.monitoring,
                serverId: widget.server.id,
              ),
            ],
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
                    pullToRefresh: panel.streams.isNotEmpty,
                    child: switch (panel) {
                      ServerPanel.overview => OverviewPanel(
                        monitoring: widget.monitoring,
                        serverId: widget.server.id,
                        visible: _destinations.index == index,
                        coverage: ServerCoverageCard(
                          monitoring: widget.monitoring,
                          serverId: widget.server.id,
                          visible: _destinations.index == index,
                        ),
                        statusCard: StatusCardButton(
                          monitoring: widget.monitoring,
                          serverId: widget.server.id,
                          serverName: widget.server.displayName,
                        ),
                      ),
                      ServerPanel.docker => DockerPanel(
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
              _MoreList(onOpen: _openPanel),
            ],
          ),
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
  ServerPanel.processes: Icons.list_alt_outlined,
  ServerPanel.services: Icons.miscellaneous_services_outlined,
  ServerPanel.jobs: Icons.schedule_outlined,
  ServerPanel.system: Icons.dns_outlined,
  ServerPanel.access: Icons.admin_panel_settings_outlined,
};

/// More's destination (03 §10.5): the panels the bottom bar has no room
/// for, each opening full-screen.
class _MoreList extends StatelessWidget {
  const _MoreList({required this.onOpen});

  final ValueChanged<ServerPanel> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      children: [
        for (final panel in ServerDetailPage.morePanels)
          ListTile(
            leading: Icon(_destinationIcons[panel]),
            title: Text(panel.label(l10n)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(panel),
          ),
      ],
    );
  }
}

/// One of More's panels full-screen (03 §10.5): its narrow layout under
/// an app bar naming it and the server, sampling while it shows and
/// pulling to refresh (PLT-02), with the return banner the server screen
/// under it shows (03 §9.5 item 6). That screen holds the server open.
/// The Services panel opens a unit's log lines in a sheet.
class _PanelPage extends StatelessWidget {
  const _PanelPage({
    required this.server,
    required this.monitoring,
    required this.fleet,
    required this.panel,
    required this.onOpenAccess,
  });

  final FleetServer server;
  final MonitoringController monitoring;
  final FleetController fleet;
  final ServerPanel panel;

  /// Pushes the Access tab, where a hidden panel's link leads.
  final VoidCallback onOpenAccess;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final serverId = server.id;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.serverPanelPageTitle(panel.label(l10n), server.displayName),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BackgroundReturnBanner(monitoring: monitoring, serverId: serverId),
            Expanded(
              child: GatedPanel(
                monitoring: monitoring,
                serverId: serverId,
                panel: panel,
                onOpenAccess: onOpenAccess,
                child: SampledSurface(
                  monitoring: monitoring,
                  serverId: serverId,
                  surface: panel.name,
                  streams: panel.streams,
                  visible: true,
                  pullToRefresh: true,
                  child: switch (panel) {
                    ServerPanel.processes => ProcessesPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: true,
                    ),
                    ServerPanel.services => ServicesPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: true,
                      logPlacement: UnitLogPlacement.sheet,
                    ),
                    ServerPanel.jobs => JobsPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: true,
                    ),
                    ServerPanel.system => SystemPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      fleet: fleet,
                    ),
                    _ => const PlaceholderPaneBody(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

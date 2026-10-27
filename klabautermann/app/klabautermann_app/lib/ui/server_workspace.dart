import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'access/access_panel.dart';
import 'access/panel_gate.dart';
import 'docker/container_details.dart' show InspectedContainer;
import 'docker/container_logs.dart' show ContainerLogsScope;
import 'docker/docker_panel.dart';
import 'jobs_panel.dart';
import 'logs/logs_panel.dart';
import 'overview_panel.dart';
import 'processes_panel.dart';
import 'connect_rejected_banner.dart';
import 'server_coverage.dart';
import 'status_card.dart';
import 'server_header.dart';
import 'server_surfaces.dart';
import 'fleet_board.dart';
import 'services_panel.dart';
import 'system_panel.dart';
import 'workspace_navigation.dart';

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
      final invitation = Center(
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
      // Centred while it fits, and scrolls when large text outgrows a
      // short window (A11Y-09), as under the first-run card (03 §9.5).
      final centred = LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: invitation,
          ),
        ),
      );
      // FL-08's board, where the composition root provides a layout.
      return switch (FleetDensityScope.maybeOf(context)) {
        final density? when fleet.servers.isNotEmpty => FleetBoard(
          fleet: fleet,
          monitoring: monitoring,
          density: density,
          invitation: centred,
        ),
        _ => centred,
      };
    }

    return DefaultTabController(
      length: _panels.length,
      child: HeaderedBody(
        headerPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        header: ServerHeader(
          server: server,
          fleet: fleet,
          monitoring: monitoring,
        ),
        // An iOS or Android tablet takes this layout and pauses in the
        // background too (03 §9.5 item 6).
        banner: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConnectRejectedBanner(monitoring: monitoring, serverId: server.id),
            BackgroundReturnBanner(monitoring: monitoring, serverId: server.id),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              isScrollable: true,
              tabs: [for (final panel in _panels) Tab(text: panel.label(l10n))],
            ),
            Expanded(
              child: _Panels(
                monitoring: monitoring,
                serverId: server.id,
                fleet: fleet,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected tab's panel, swapped in place, while [serverId] is held
/// open. A panel stays built once opened, so whether it samples follows
/// the tab controller's index (03 §6.4). A panel the access rules hide
/// links to the Access tab instead (03 §10.4).
class _Panels extends StatefulWidget {
  const _Panels({
    required this.monitoring,
    required this.serverId,
    required this.fleet,
  });

  final MonitoringController monitoring;
  final String serverId;
  final FleetController fleet;

  @override
  State<_Panels> createState() => _PanelsState();
}

class _PanelsState extends State<_Panels> {
  /// Where a hidden panel's link puts the keyboard: the link hides with
  /// its panel, so focus moves into the Access tab (03 §10.10).
  final FocusNode _accessFocus = FocusNode();

  /// The desktop shell's container logs, which show in the Docker tab.
  ValueNotifier<InspectedContainer?>? _logs;
  WorkspaceNavigation? _navigation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final navigation = WorkspaceNavigationScope.maybeOf(context);
    if (!identical(navigation, _navigation)) {
      _navigation?.removeListener(_onNavigation);
      _navigation = navigation?..addListener(_onNavigation);
      // A request that selected this server came before these tabs did.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onNavigation();
      });
    }
    final logs = ContainerLogsScope.find(context);
    if (identical(logs, _logs)) return;
    _logs?.removeListener(_onLogsOpened);
    _logs = logs?..addListener(_onLogsOpened);
  }

  @override
  void didUpdateWidget(_Panels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId) return;
    // These tabs now show another server, which a request may have
    // selected; the tab controller changes after this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onNavigation();
    });
  }

  @override
  void dispose() {
    _navigation?.removeListener(_onNavigation);
    _logs?.removeListener(_onLogsOpened);
    _accessFocus.dispose();
    super.dispose();
  }

  /// Logs opened from outside the Docker tab, as the inspector does while
  /// another tab shows, bring the Docker tab forward so they show.
  void _onLogsOpened() {
    final opened = _logs?.value;
    if (opened == null || opened.serverId != widget.serverId) return;
    DefaultTabController.of(context).index = ServerWorkspace._panels.indexOf(
      ServerPanel.docker,
    );
  }

  /// Shows the tab the command palette asked for, once this server's.
  void _onNavigation() {
    final navigation = _navigation;
    final request = navigation?.request;
    if (navigation == null || request == null) return;
    if (request.serverId != widget.serverId) return;
    navigation.consumeRequest(request);
    DefaultTabController.of(context).index = ServerWorkspace._panels.indexOf(
      request.panel,
    );
  }

  void _openAccess(TabController tabs) {
    tabs.index = ServerWorkspace._panels.indexOf(ServerPanel.access);
    // The tab is built on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _accessFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final monitoring = widget.monitoring;
    final serverId = widget.serverId;
    final tabs = DefaultTabController.of(context);
    return OpenServer(
      monitoring: monitoring,
      serverId: serverId,
      child: ListenableBuilder(
        listenable: tabs,
        builder: (context, _) => SelectedTabView(
          children: [
            for (final (index, panel) in ServerWorkspace._panels.indexed)
              GatedPanel(
                monitoring: monitoring,
                serverId: serverId,
                panel: panel,
                onOpenAccess: () => _openAccess(tabs),
                child: SampledSurface(
                  monitoring: monitoring,
                  serverId: serverId,
                  surface: panel.name,
                  streams: panel.streams,
                  visible: tabs.index == index,
                  child: switch (panel) {
                    ServerPanel.overview => OverviewPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                      coverage: ServerCoverageCard(
                        monitoring: monitoring,
                        serverId: serverId,
                        visible: tabs.index == index,
                      ),
                      statusCard: StatusCardButton(
                        monitoring: monitoring,
                        serverId: serverId,
                        serverName:
                            widget.fleet.selectedServer?.displayName ??
                            serverId,
                      ),
                    ),
                    ServerPanel.processes => ProcessesPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                    ),
                    ServerPanel.services => ServicesPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                    ),
                    ServerPanel.logs => LogsPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                    ),
                    ServerPanel.jobs => JobsPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                    ),
                    ServerPanel.docker => DockerPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      visible: tabs.index == index,
                    ),
                    ServerPanel.system => SystemPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      fleet: widget.fleet,
                    ),
                    ServerPanel.access => AccessPanel(
                      monitoring: monitoring,
                      serverId: serverId,
                      focusNode: _accessFocus,
                    ),
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

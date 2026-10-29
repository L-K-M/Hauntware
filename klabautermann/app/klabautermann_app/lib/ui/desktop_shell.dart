import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show macosTrafficLightsInset;
import 'package:ghost_ui/ghost_ui.dart' show formatShortcutActivator;
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../controllers/window_panes.dart';
import '../l10n/app_localizations.dart';
import 'coverage.dart';
import 'docker/container_details.dart';
import 'docker/container_logs.dart';
import 'fleet_rail.dart';
import 'inspector_pane.dart';
import 'macos_toolbar_band.dart';
import 'server_workspace.dart';
import 'sidebar_kit.dart' show SidebarThemeTokens;
import 'window_pane_actions.dart';
import 'workspace_dock.dart';
import 'workspace_navigation.dart';

/// The desktop three-pane shell of 03 §10.2, shown at widths of 960 px
/// and up: fleet rail, server workspace, inspector. It holds the
/// container the inspector shows, which the workspace's Containers
/// sub-tab opens ([ContainerInspectionScope]), and the container whose
/// logs the Docker tab shows, which the inspector or a row opens
/// ([ContainerLogsScope]), and the workspace's bottom dock (OV-10,
/// [WorkspaceDockScope]).
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.coverage,
    required this.onOpenSettings,
    this.onAddServer,
    this.sync,
    this.navigation,
    required this.panes,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Heads the workspace with the first-run card (03 §9.5 item 1).
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;
  final SyncController? sync;

  /// Whether the rail and the inspector show: the composition root keeps
  /// them in settings.json, the shell in memory otherwise.
  final WindowPanesController panes;

  /// Where the command palette sends the workspace: its tabs follow the
  /// requests and the inspector takes the containers.
  final WorkspaceNavigation? navigation;

  /// The rail's fixed width; the kit's rows keep their own insets.
  static const double railWidth = 260;

  /// The inspector's fixed width (03 §10.2's right column).
  static const double inspectorWidth = 300;

  /// The sidebar toggle, in the rail's band while it shows and leading
  /// the header while it is hidden.
  static const sidebarToggleKey = ValueKey('shell.sidebarToggle');

  /// The inspector toggle, ending the header.
  static const inspectorToggleKey = ValueKey('shell.inspectorToggle');

  /// The selected server's name in the header band.
  static const serverTitleKey = ValueKey('shell.serverTitle');

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  /// The inspector's container, which belongs to the selected server: a
  /// selection of another lets it go.
  final _inspection = ValueNotifier<InspectedContainer?>(null);

  /// The container whose logs the Docker tab shows, which belongs to the
  /// selected server too.
  final _logs = ValueNotifier<InspectedContainer?>(null);

  /// The workspace's dock, whose items outlive a change of server.
  final _dock = WorkspaceDock();

  @override
  void initState() {
    super.initState();
    widget.fleet.addListener(_onFleetChanged);
    widget.navigation?.addListener(_onNavigation);
  }

  @override
  void didUpdateWidget(DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navigation != oldWidget.navigation) {
      oldWidget.navigation?.removeListener(_onNavigation);
      widget.navigation?.addListener(_onNavigation);
    }
    if (widget.fleet == oldWidget.fleet) return;
    oldWidget.fleet.removeListener(_onFleetChanged);
    widget.fleet.addListener(_onFleetChanged);
    _onFleetChanged();
  }

  @override
  void dispose() {
    widget.navigation?.removeListener(_onNavigation);
    widget.fleet.removeListener(_onFleetChanged);
    _inspection.dispose();
    _logs.dispose();
    _dock.dispose();
    super.dispose();
  }

  /// A container the palette picked goes to the inspector; the selection
  /// that came with it has already let the previous one go.
  void _onNavigation() {
    if (widget.navigation?.takeContainer() case final container?) {
      _inspection.value = container;
    }
  }

  /// [child] under the palette's navigation, which the workspace's tabs
  /// follow; as is without one.
  Widget _withNavigation(Widget child) => switch (widget.navigation) {
    final navigation? => WorkspaceNavigationScope(
      navigation: navigation,
      child: child,
    ),
    null => child,
  };

  void _onFleetChanged() {
    final selected = widget.fleet.selectedServer?.id;
    for (final shown in [_inspection, _logs]) {
      final container = shown.value;
      if (container != null && container.serverId != selected) {
        shown.value = null;
      }
    }
    // A server that left the fleet takes its dock items, shells included.
    final known = {for (final server in widget.fleet.servers) server.id};
    for (final serverId in {for (final item in _dock.items) item.serverId}) {
      if (!known.contains(serverId)) _dock.forgetServer(serverId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClaimMacosToolbarBand(
      // Under the macOS unified titlebar the header and the rail's band
      // draw in the band at the window's top, where AppKit takes every
      // click for window drag unless a passthrough view hands it back.
      child: _passthroughScope(
        Scaffold(
          body: SafeArea(
            top: false,
            // The context under the SafeArea: its MediaQuery has the side
            // and bottom insets consumed and the Scaffold's keyboard inset
            // removed. DesktopShell's own context would bring them back.
            child: Builder(
              builder: (context) {
                // The remaining top inset: a tablet's status bar (the
                // macOS band is already claimed). The bands paint up
                // through it and start their controls below.
                final top = MediaQuery.paddingOf(context).top;
                return MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: _withNavigation(
                    ContainerInspectionScope(
                      inspection: _inspection,
                      child: ContainerLogsScope(
                        logs: _logs,
                        child: WorkspaceDockScope(
                          dock: _dock,
                          child: _panes(context, top),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The three columns: [rail band and rail] | [header over workspace and
  /// inspector], a hidden pane leaving the column and its divider to the
  /// workspace.
  Widget _panes(BuildContext context, double top) {
    final fleet = widget.fleet;
    final monitoring = widget.monitoring;
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.panes, fleet]),
      builder: (context, _) {
        final sidebar = widget.panes.sidebarShown;
        final inspector = widget.panes.inspectorShown;
        return Row(
          children: [
            if (sidebar) ...[
              SizedBox(
                width: DesktopShell.railWidth,
                child: ColoredBox(
                  color: SidebarThemeTokens.of(context).sidebarBackground,
                  child: Column(
                    children: [
                      _Band(
                        top: top,
                        child: Padding(
                          padding: EdgeInsetsDirectional.only(
                            start: _leadingInset(context),
                          ),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: _clickable(
                              context,
                              _PaneToggle(
                                key: DesktopShell.sidebarToggleKey,
                                pane: WindowPane.sidebar,
                                shown: sidebar,
                                onToggle: () => unawaited(
                                  toggleWindowPane(
                                    context,
                                    widget.panes,
                                    WindowPane.sidebar,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Divider(height: 1, color: colors.outlineVariant),
                      Expanded(
                        child: FleetRail(
                          fleet: fleet,
                          monitoring: monitoring,
                          onOpenSettings: widget.onOpenSettings,
                          onAddServer: widget.onAddServer,
                          sync: widget.sync,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              VerticalDivider(width: 1, color: colors.outlineVariant),
            ],
            Expanded(
              child: Column(
                children: [
                  _Band(
                    top: top,
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: sidebar ? 8 : _leadingInset(context),
                        end: 8,
                      ),
                      child: Row(
                        children: [
                          if (!sidebar) ...[
                            _clickable(
                              context,
                              _PaneToggle(
                                key: DesktopShell.sidebarToggleKey,
                                pane: WindowPane.sidebar,
                                shown: sidebar,
                                onToggle: () => unawaited(
                                  toggleWindowPane(
                                    context,
                                    widget.panes,
                                    WindowPane.sidebar,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: switch (fleet.selectedServer) {
                              final server? => Text(
                                key: DesktopShell.serverTitleKey,
                                server.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              null => const SizedBox.shrink(),
                            },
                          ),
                          const SizedBox(width: 8),
                          _clickable(
                            context,
                            _PaneToggle(
                              key: DesktopShell.inspectorToggleKey,
                              pane: WindowPane.inspector,
                              shown: inspector,
                              onToggle: () => unawaited(
                                toggleWindowPane(
                                  context,
                                  widget.panes,
                                  WindowPane.inspector,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, color: colors.outlineVariant),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: CoverageHeader(
                            placement: CoveragePlacement.desktopWorkspace,
                            coverage: widget.coverage,
                            fleet: fleet,
                            child: ServerWorkspace(
                              fleet: fleet,
                              monitoring: monitoring,
                              // The header names the selected server.
                              showTitle: false,
                            ),
                          ),
                        ),
                        if (inspector) ...[
                          VerticalDivider(
                            width: 1,
                            color: colors.outlineVariant,
                          ),
                          SizedBox(
                            width: DesktopShell.inspectorWidth,
                            child: ColoredBox(
                              color: colors.surfaceContainerLow,
                              child: InspectorPane(
                                fleet: fleet,
                                monitoring: monitoring,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Where the window's leading controls start: after the traffic lights
/// under the macOS titlebar, in full screen too, and at the edge
/// everywhere else.
double _leadingInset(BuildContext context) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? macosTrafficLightsInset
    : 8;

/// [child] as a control inside the macOS toolbar band: there AppKit takes
/// every click for window drag unless a passthrough view hands it back.
/// Plain Flutter on every other platform.
Widget _clickable(BuildContext context, Widget child) =>
    MacosToolbarBandScope.unifiedToolbarOf(context)
    ? MacosToolbarPassthrough(child: child)
    : child;

/// [child] with the passthrough views inside it registered, on macOS.
Widget _passthroughScope(Widget child) => Builder(
  builder: (context) => MacosToolbarBandScope.unifiedToolbarOf(context)
      ? MacosToolbarPassthroughScope(child: child)
      : child,
);

/// The 52 pt strip level with the macOS band and the header: the rail's
/// sidebar toggle, and the header itself above the workspace. [top] is a
/// tablet's status bar, which the controls start below while the strip's
/// colour paints through it.
class _Band extends StatelessWidget {
  const _Band({required this.top, required this.child});

  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: top + macosToolbarBandHeight,
      child: Padding(
        padding: EdgeInsets.only(top: top),
        child: child,
      ),
    );
  }
}

/// A side pane's toggle (Séance's `_PaneToggleButton`): the suite's
/// `view_sidebar` glyph, its panel on the leading side for the rail and
/// the trailing one for the inspector, named for what it would do with
/// the pane's shortcut in its tooltip.
class _PaneToggle extends StatelessWidget {
  const _PaneToggle({
    super.key,
    required this.pane,
    required this.shown,
    required this.onToggle,
  });

  final WindowPane pane;
  final bool shown;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    final label = switch ((pane, shown)) {
      (WindowPane.sidebar, true) => l10n.sidebarToggleHide,
      (WindowPane.sidebar, false) => l10n.sidebarToggleShow,
      (WindowPane.inspector, true) => l10n.inspectorToggleHide,
      (WindowPane.inspector, false) => l10n.inspectorToggleShow,
    };
    final keys = formatShortcutActivator(
      windowPaneChord(pane, platform),
      platform,
    );
    final tooltip = keys == null ? label : l10n.paneToggleTooltip(label, keys);
    // view_sidebar draws its panel on the right: mirrored for the panel
    // on the reading direction's start.
    final ltr = Directionality.of(context) == TextDirection.ltr;
    final leading = pane == WindowPane.sidebar;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onToggle,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 30,
            height: 26,
            child: Transform.flip(
              flipX: leading == ltr,
              child: Icon(
                Icons.view_sidebar_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

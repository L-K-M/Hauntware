import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import 'coverage.dart';
import 'docker/container_details.dart';
import 'docker/container_logs.dart';
import 'fleet_rail.dart';
import 'inspector_pane.dart';
import 'server_workspace.dart';
import 'sidebar_kit.dart' show SidebarThemeTokens;

/// The desktop three-pane shell of 03 §10.2, shown at widths of 960 px
/// and up: fleet rail, server workspace, inspector. It holds the
/// container the inspector shows, which the workspace's Containers
/// sub-tab opens ([ContainerInspectionScope]), and the container whose
/// logs the Docker tab shows, which the inspector or a row opens
/// ([ContainerLogsScope]).
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.coverage,
    required this.onOpenSettings,
    this.onAddServer,
    this.sync,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Heads the workspace with the first-run card (03 §9.5 item 1).
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;
  final SyncController? sync;

  /// The rail's fixed width; the kit's rows keep their own insets.
  static const double railWidth = 260;

  /// The inspector's fixed width (03 §10.2's right column).
  static const double inspectorWidth = 300;

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

  @override
  void initState() {
    super.initState();
    widget.fleet.addListener(_onFleetChanged);
  }

  @override
  void didUpdateWidget(DesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fleet == oldWidget.fleet) return;
    oldWidget.fleet.removeListener(_onFleetChanged);
    widget.fleet.addListener(_onFleetChanged);
    _onFleetChanged();
  }

  @override
  void dispose() {
    widget.fleet.removeListener(_onFleetChanged);
    _inspection.dispose();
    _logs.dispose();
    super.dispose();
  }

  void _onFleetChanged() {
    final selected = widget.fleet.selectedServer?.id;
    for (final shown in [_inspection, _logs]) {
      final container = shown.value;
      if (container != null && container.serverId != selected) {
        shown.value = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fleet = widget.fleet;
    final monitoring = widget.monitoring;
    final colors = Theme.of(context).colorScheme;
    // The top inset: the macOS toolbar band the traffic lights sit in
    // (ReserveMacosToolbarBand), or a tablet's status bar. Each pane paints
    // its background up through it and starts its content below, so the
    // rail's colour runs behind the traffic lights like a Mac sidebar and
    // nothing interactive sits under them. The panes' own scroll views
    // must not pad for it again, so it leaves their MediaQuery.
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: SafeArea(
        top: false,
        // The context under the SafeArea: its MediaQuery has the side and
        // bottom insets consumed and the Scaffold's keyboard inset removed.
        // DesktopShell's own context would bring all of them back.
        child: Builder(
          builder: (context) => MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: ContainerInspectionScope(
              inspection: _inspection,
              child: ContainerLogsScope(
                logs: _logs,
                child: Row(
                  children: [
                    SizedBox(
                      width: DesktopShell.railWidth,
                      child: _BelowTopInset(
                        inset: top,
                        color: SidebarThemeTokens.of(context).sidebarBackground,
                        child: FleetRail(
                          fleet: fleet,
                          monitoring: monitoring,
                          onOpenSettings: widget.onOpenSettings,
                          onAddServer: widget.onAddServer,
                          sync: widget.sync,
                        ),
                      ),
                    ),
                    VerticalDivider(width: 1, color: colors.outlineVariant),
                    Expanded(
                      child: _BelowTopInset(
                        inset: top,
                        child: CoverageHeader(
                          placement: CoveragePlacement.desktopWorkspace,
                          coverage: widget.coverage,
                          fleet: fleet,
                          child: ServerWorkspace(
                            fleet: fleet,
                            monitoring: monitoring,
                          ),
                        ),
                      ),
                    ),
                    VerticalDivider(width: 1, color: colors.outlineVariant),
                    SizedBox(
                      width: DesktopShell.inspectorWidth,
                      child: _BelowTopInset(
                        inset: top,
                        color: colors.surfaceContainerLow,
                        child: InspectorPane(
                          fleet: fleet,
                          monitoring: monitoring,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One pane under the top inset: [color] fills the inset strip above
/// [child], which starts below it. Without a colour the Scaffold's shows.
class _BelowTopInset extends StatelessWidget {
  const _BelowTopInset({required this.inset, required this.child, this.color});

  final double inset;
  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padded = Padding(
      padding: EdgeInsets.only(top: inset),
      child: child,
    );
    final fill = color;
    return fill == null ? padded : ColoredBox(color: fill, child: padded);
  }
}

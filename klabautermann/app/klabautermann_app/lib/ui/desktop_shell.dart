import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import 'coverage.dart';
import 'fleet_rail.dart';
import 'inspector_pane.dart';
import 'server_workspace.dart';
import 'sidebar_kit.dart' show SidebarThemeTokens;

/// The desktop three-pane shell of 03 §10.2, shown at widths of 960 px
/// and up: fleet rail, server workspace, inspector.
class DesktopShell extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
            child: Row(
              children: [
                SizedBox(
                  width: railWidth,
                  child: _BelowTopInset(
                    inset: top,
                    color: SidebarThemeTokens.of(context).sidebarBackground,
                    child: FleetRail(
                      fleet: fleet,
                      monitoring: monitoring,
                      onOpenSettings: onOpenSettings,
                      onAddServer: onAddServer,
                      sync: sync,
                    ),
                  ),
                ),
                VerticalDivider(width: 1, color: colors.outlineVariant),
                Expanded(
                  child: _BelowTopInset(
                    inset: top,
                    child: CoverageHeader(
                      placement: CoveragePlacement.desktopWorkspace,
                      coverage: coverage,
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
                  width: inspectorWidth,
                  child: _BelowTopInset(
                    inset: top,
                    color: colors.surfaceContainerLow,
                    child: InspectorPane(fleet: fleet, monitoring: monitoring),
                  ),
                ),
              ],
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

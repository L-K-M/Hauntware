import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import 'fleet_rail.dart';
import 'inspector_pane.dart';
import 'server_workspace.dart';

/// The desktop three-pane shell of 03 §10.2, shown at widths of 960 px
/// and up: fleet rail, server workspace, inspector.
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.onOpenSettings,
    this.onAddServer,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;

  /// The rail's fixed width; the kit's rows keep their own insets.
  static const double railWidth = 260;

  /// The inspector's fixed width (03 §10.2's right column).
  static const double inspectorWidth = 300;

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).colorScheme.outlineVariant;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: railWidth,
              child: FleetRail(
                fleet: fleet,
                onOpenSettings: onOpenSettings,
                onAddServer: onAddServer,
              ),
            ),
            VerticalDivider(width: 1, color: dividerColor),
            Expanded(
              child: ServerWorkspace(fleet: fleet, monitoring: monitoring),
            ),
            VerticalDivider(width: 1, color: dividerColor),
            SizedBox(
              width: inspectorWidth,
              child: InspectorPane(fleet: fleet),
            ),
          ],
        ),
      ),
    );
  }
}

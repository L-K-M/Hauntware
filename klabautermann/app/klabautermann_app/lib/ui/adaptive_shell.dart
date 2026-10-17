import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import 'desktop_shell.dart';
import 'phone_shell.dart';

/// 03 §10.2: the desktop layout takes over at this width.
const double kDesktopShellMinWidth = 960;

/// Picks the shell for the window's width (03 §10.2, §10.5). Widths
/// between the phone and desktop breakpoints use the phone stack until
/// the v1 tablet two-pane lands.
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
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
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;

  /// The sync account behind the sync control; null shows the control
  /// idle with no action.
  final SyncController? sync;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kDesktopShellMinWidth) {
      return DesktopShell(
        fleet: fleet,
        monitoring: monitoring,
        coverage: coverage,
        onOpenSettings: onOpenSettings,
        onAddServer: onAddServer,
        sync: sync,
      );
    }
    return PhoneShell(
      fleet: fleet,
      monitoring: monitoring,
      coverage: coverage,
      onOpenSettings: onOpenSettings,
      onAddServer: onAddServer,
      sync: sync,
    );
  }
}

import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../controllers/window_panes.dart';
import 'desktop_shell.dart';
import 'phone_shell.dart';
import 'workspace_navigation.dart';

/// 03 §10.2: the desktop layout takes over at this width.
const double kDesktopShellMinWidth = 960;

/// Whether [context]'s window is wide enough for the desktop shell.
bool showsDesktopShell(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopShellMinWidth;

/// Picks the shell for the window's width (03 §10.2, §10.5). Under the
/// desktop breakpoint [PhoneShell] stacks on a phone and splits on a
/// tablet (PLT-05).
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
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
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;

  /// The sync account behind the sync control; null shows the control
  /// idle with no action.
  final SyncController? sync;

  /// Where the command palette sends the desktop workspace.
  final WorkspaceNavigation? navigation;

  /// The desktop shell's side panes; the phone shell never reads them.
  final WindowPanesController panes;

  @override
  Widget build(BuildContext context) {
    if (showsDesktopShell(context)) {
      return DesktopShell(
        fleet: fleet,
        monitoring: monitoring,
        coverage: coverage,
        onOpenSettings: onOpenSettings,
        onAddServer: onAddServer,
        sync: sync,
        navigation: navigation,
        panes: panes,
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

import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'coverage.dart';
import 'fleet_rows.dart';
import 'server_detail_page.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';

/// The phone home of 03 §10.5: the fleet list is home, a server opens a
/// pushed screen. Tablet two-pane is v1; widths under the desktop
/// breakpoint share this stack meanwhile.
class PhoneShell extends StatelessWidget {
  const PhoneShell({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.coverage,
    required this.onOpenSettings,
    this.onAddServer,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Heads the fleet list with the first-run card and the coverage chip
  /// (03 §9.5).
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.fleetTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.addServer,
            onPressed: onAddServer,
          ),
          // FL-02: only where the platform has an ssh_config, which is a
          // desktop window narrower than the desktop breakpoint, never a
          // phone.
          if (fleet.canImportSshConfig)
            ListenableBuilder(
              listenable: fleet,
              builder: (context, _) => IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: l10n.importSshConfig,
                onPressed: fleet.isImportingSshConfig
                    ? null
                    : () => importSshConfigWithFeedback(context, fleet),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.openSettings,
            onPressed: onOpenSettings,
          ),
        ],
      ),
      // In the SafeArea's place: it keeps the card, chip and list inside.
      body: CoverageHeader(
        placement: CoveragePlacement.phoneFleetList,
        coverage: coverage,
        fleet: fleet,
        child: SidebarKitScope(
          strings: klabautermannSidebarStrings(l10n),
          layout: SidebarKitLayout.list,
          // The assert in SidebarKitScope pins list layout to comfortable.
          density: SidebarKitDensity.comfortable,
          background: Theme.of(context).colorScheme.surface,
          child: FleetServerList(
            fleet: fleet,
            monitoring: monitoring,
            onOpen: (server) {
              fleet.select(server.id);
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ServerDetailPage(
                    server: server,
                    fleet: fleet,
                    monitoring: monitoring,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

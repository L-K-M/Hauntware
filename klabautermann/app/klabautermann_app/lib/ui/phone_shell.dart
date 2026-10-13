import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rail.dart';
import 'server_detail_page.dart';
import 'sidebar_kit.dart';

/// The phone home of 03 §10.5: the fleet list is home, a server opens a
/// pushed screen. Tablet two-pane is v1; widths under the desktop
/// breakpoint share this stack meanwhile.
class PhoneShell extends StatelessWidget {
  const PhoneShell({
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
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.openSettings,
            onPressed: onOpenSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SidebarKitScope(
          strings: klabautermannSidebarStrings(l10n),
          layout: SidebarKitLayout.list,
          // The assert in SidebarKitScope pins list layout to comfortable.
          density: SidebarKitDensity.comfortable,
          background: Theme.of(context).colorScheme.surface,
          child: ListenableBuilder(
            listenable: fleet,
            builder: (context, _) {
              final servers = fleet.servers;
              if (servers.isEmpty) {
                return const FleetEmptyState();
              }
              return ListView(
                children: [
                  for (final server in servers)
                    SidebarRow(
                      mark: const Icon(Icons.dns_outlined),
                      title: server.displayName,
                      subtitle: server.address,
                      onActivate: (_) {
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
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

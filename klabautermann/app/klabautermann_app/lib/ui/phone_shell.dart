import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../l10n/app_localizations.dart';
import 'coverage.dart';
import 'fleet_rows.dart';
import 'server_coverage.dart' show NoticeBanner;
import 'server_detail_page.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';
import 'sync_sign_in.dart';

/// The phone home of 03 §10.5: the fleet list is home, a server opens a
/// pushed screen. Tablet two-pane is v1; widths under the desktop
/// breakpoint share this stack meanwhile. When a server's screen closes
/// because the server left the fleet (SYN-08), the list says so until
/// the user dismisses it or opens a server.
class PhoneShell extends StatefulWidget {
  const PhoneShell({
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

  /// Heads the fleet list with the first-run card and the coverage chip
  /// (03 §9.5).
  final CoverageController coverage;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddServer;

  /// The sync account behind the app bar's sync button (03 §4.3): it signs
  /// in, or runs a round once signed in. Null hides the button.
  final SyncController? sync;

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  /// The name of the server whose screen closed as it left the fleet.
  String? _departed;

  Future<void> _open(FleetServer server) async {
    final fleet = widget.fleet;
    fleet.select(server.id);
    setState(() => _departed = null);
    final exit = await Navigator.of(context).push(
      MaterialPageRoute<ServerScreenExit>(
        builder: (_) => ServerDetailPage(
          server: server,
          fleet: fleet,
          monitoring: widget.monitoring,
        ),
      ),
    );
    if (!mounted || exit != ServerScreenExit.leftFleet) return;
    setState(() => _departed = server.displayName);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fleet = widget.fleet;
    final departed = _departed;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.fleetTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.addServer,
            onPressed: widget.onAddServer,
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
          if (widget.sync case final sync?)
            ListenableBuilder(
              listenable: sync,
              builder: (context, _) => IconButton(
                icon: const Icon(Icons.sync),
                tooltip: syncActionTooltip(l10n, sync),
                onPressed: sync.busy
                    ? null
                    : () => runSyncAction(context, sync),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.openSettings,
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      // In the SafeArea's place: it keeps the card, chip and list inside.
      body: CoverageHeader(
        placement: CoveragePlacement.phoneFleetList,
        coverage: widget.coverage,
        fleet: fleet,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (departed != null)
              NoticeBanner(
                icon: Icons.info_outline,
                text: l10n.fleetServerLeftNotice(departed),
                dismissLabel: l10n.fleetServerLeftDismiss,
                onDismiss: () => setState(() => _departed = null),
              ),
            // Last, so the list keeps its state as the notice comes and
            // goes.
            Expanded(
              child: SidebarKitScope(
                strings: klabautermannSidebarStrings(l10n),
                layout: SidebarKitLayout.list,
                // The assert in SidebarKitScope pins list layout to
                // comfortable.
                density: SidebarKitDensity.comfortable,
                background: Theme.of(context).colorScheme.surface,
                child: FleetServerList(
                  fleet: fleet,
                  monitoring: widget.monitoring,
                  onOpen: (server) => unawaited(_open(server)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

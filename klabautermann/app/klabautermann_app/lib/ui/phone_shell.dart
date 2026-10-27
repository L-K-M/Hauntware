import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../l10n/app_localizations.dart';
import 'alerts.dart';
import 'attention.dart';
import 'coverage.dart';
import 'endpoint_confirmation.dart';
import 'fleet_rows.dart';
import 'server_coverage.dart' show NoticeBanner;
import 'server_detail_page.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';
import 'sync_sign_in.dart';

/// 03 §10.5: a window whose shorter side is at least this wide splits
/// into the fleet list and the selected server (PLT-05), as Android's
/// sw600dp does. A tablet splits under the desktop breakpoint, and so
/// does a desktop window that is tall enough; a phone held sideways stays
/// in the stack, where a screen it pushed would otherwise end up over
/// the split.
const double kTabletSplitMinShortestSide = 600;

/// The fleet list's width beside the selected server.
const double _splitListWidth = 320;

/// The phone and tablet home of 03 §10.5. On a phone the fleet list is
/// home and a server opens a pushed screen; on a tablet the list stays
/// beside the selected server's screen. When a server's screen closes
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

  /// Whether the last build split the window.
  var _split = false;

  /// The selected server, to name it once it has left the fleet.
  FleetServer? _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.fleet.selectedServer;
    widget.fleet.addListener(_onFleetChanged);
  }

  @override
  void dispose() {
    widget.fleet.removeListener(_onFleetChanged);
    super.dispose();
  }

  /// SYN-08 in the split: the fleet clears the selection of a server that
  /// left it, and the pane closes with everything it opened (More's
  /// panels, sheets and dialogs), as the stack's pushed screen does.
  void _onFleetChanged() {
    final fleet = widget.fleet;
    final shown = _shown;
    _shown = fleet.selectedServer;
    if (!_split || shown == null || _shown != null) return;
    if (fleet.servers.any((server) => server.id == shown.id)) return;

    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).popUntil((other) => other == route);
    }
    setState(() => _departed = shown.displayName);
  }

  Future<void> _open(FleetServer server) async {
    final fleet = widget.fleet;
    fleet.select(server.id);
    setState(() => _departed = null);
    if (_split) return;
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
    _split =
        MediaQuery.sizeOf(context).shortestSide >= kTabletSplitMinShortestSide;
    final list = _fleetList(context, l10n);
    if (!_split) return list;

    // The list keeps its place while the selection changes; an empty
    // fleet's invitation takes the whole window.
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        if (fleet.servers.isEmpty) return list;
        final selected = fleet.selectedServer;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: _splitListWidth, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? Scaffold(
                      appBar: AppBar(),
                      body: Center(child: Text(l10n.fleetSplitChooseServer)),
                    )
                  : ServerDetailPage(
                      key: ValueKey(selected.id),
                      server: selected,
                      fleet: fleet,
                      monitoring: widget.monitoring,
                      placement: ServerScreenPlacement.pane,
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _fleetList(BuildContext context, AppLocalizations l10n) {
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
                  showSelection: _split,
                  // The raised alerts (ALR-01), then 03 §4.3 step 3's
                  // synced servers waiting to be confirmed.
                  header: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AlertsNotice(
                        fleet: fleet,
                        onOpenServer: (server) => unawaited(_open(server)),
                      ),
                      AttentionNotice(
                        fleet: fleet,
                        monitoring: widget.monitoring,
                        onOpenServer: (server) => unawaited(_open(server)),
                      ),
                      EndpointsPendingNotice(fleet: fleet),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

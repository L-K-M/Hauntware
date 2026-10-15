import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'fleet_rows.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';

/// The desktop rail of 03 §10.2: a section header over the filter and the
/// fleet rows ([FleetServerList]) and the kit's bottom bar with the add
/// menu, sync chip and settings gear.
class FleetRail extends StatefulWidget {
  const FleetRail({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.onOpenSettings,
    this.onAddServer,
  });

  final FleetController fleet;

  /// Feeds the rows' pressure bars and freshness (03 §10.3).
  final MonitoringController monitoring;

  final VoidCallback onOpenSettings;

  /// The add-server entry point; null renders the menu verb disabled
  /// (enrollment lands with F3's catalog).
  final VoidCallback? onAddServer;

  @override
  State<FleetRail> createState() => _FleetRailState();
}

class _FleetRailState extends State<FleetRail> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = SidebarThemeTokens.of(context);
    return SidebarKitScope(
      strings: klabautermannSidebarStrings(l10n),
      child: ColoredBox(
        color: tokens.sidebarBackground,
        child: ListenableBuilder(
          listenable: widget.fleet,
          builder: (context, _) {
            final servers = widget.fleet.servers;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SidebarSectionHeader(
                  title: l10n.fleetSectionServers,
                  count: servers.length,
                  collapsed: _collapsed,
                  onToggle: () => setState(() => _collapsed = !_collapsed),
                ),
                Expanded(
                  child: FleetServerList(
                    fleet: widget.fleet,
                    monitoring: widget.monitoring,
                    collapsed: _collapsed,
                    showSelection: true,
                    onOpen: (server) => widget.fleet.select(server.id),
                  ),
                ),
                SidebarBottomBar(
                  addEntries: () => [
                    SidebarMenuAction(
                      label: l10n.addServer,
                      onSelected: widget.onAddServer,
                    ),
                    // FL-02: desktops only; phones have no ssh_config.
                    if (widget.fleet.canImportSshConfig)
                      SidebarMenuAction(
                        label: l10n.importSshConfig,
                        onSelected: widget.fleet.isImportingSshConfig
                            ? null
                            : () => importSshConfigWithFeedback(
                                context,
                                widget.fleet,
                              ),
                      ),
                  ],
                  sync: SidebarSyncChipData(
                    label: l10n.syncFleet,
                    // Pull-only MVP (D14): the chip shows the idle sync
                    // state until sync enrollment exists to report it.
                    tone: SidebarSyncTone.muted,
                  ),
                  onSettings: widget.onOpenSettings,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The localized word for a [LinkStatus]: the text half of the dot
/// vocabulary (03 §10.3), used wherever the dot's colour needs words. The
/// reasons a status carries are worded by the surfaces that explain them.
String linkStatusWord(AppLocalizations l10n, LinkStatus status) {
  return switch (status) {
    LinkIdle() => l10n.statusDisconnected,
    LinkConnecting() => l10n.statusConnecting,
    LinkAuthenticating() => l10n.statusAuthenticating,
    LinkReady() => l10n.statusConnected,
    LinkDegraded() => l10n.statusLimited,
    LinkBackoff() => l10n.statusWaitingToReconnect,
    LinkNeedsUser() => l10n.statusNeedsInput,
    LinkBlocked() => l10n.statusBlocked,
    LinkClosed(reason: LinkClosedReason.closedByOwner, failure: null) =>
      l10n.statusDisconnected,
    LinkClosed(
      reason: LinkClosedReason.closedByOwner || LinkClosedReason.connectFailed,
    ) =>
      l10n.statusFailed,
    LinkClosed() => l10n.statusConnectionLost,
  };
}

/// The rail's empty state (03 §10.2, M1a): a short invitation, because the
/// first-run flow of §4.3 is its own milestone.
class FleetEmptyState extends StatelessWidget {
  const FleetEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.fleetEmptyTitle,
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.fleetEmptyBody,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

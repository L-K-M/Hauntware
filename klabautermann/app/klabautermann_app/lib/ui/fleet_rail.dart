import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:klabautermann_core/klabautermann_core.dart' show LinkPhase;

import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';

/// The desktop rail of 03 §10.2: a section header over the fleet rows and
/// the kit's bottom bar with the add menu, sync chip and settings gear.
/// `ghost_servers` (F4) takes over the section and row builders when it
/// lands; this keeps the kit's chrome already.
class FleetRail extends StatefulWidget {
  const FleetRail({
    super.key,
    required this.fleet,
    required this.onOpenSettings,
    this.onAddServer,
  });

  final FleetController fleet;
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
                  child: servers.isEmpty
                      ? const FleetEmptyState()
                      : ListView(
                          children: [
                            if (!_collapsed)
                              for (final server in servers)
                                FleetServerRow(
                                  server: server,
                                  fleet: widget.fleet,
                                ),
                          ],
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

/// The localized word for a [LinkPhase]: the text half of the dot
/// vocabulary (03 §10.3), used wherever the dot's colour needs words.
String linkPhaseWord(AppLocalizations l10n, LinkPhase phase) {
  return switch (phase) {
    LinkPhase.connected => l10n.statusConnected,
    LinkPhase.connecting => l10n.statusConnecting,
    LinkPhase.failed => l10n.statusFailed,
    LinkPhase.disconnected => l10n.statusDisconnected,
  };
}

/// One server row of 03 §10.3: mark, one status dot composed into its
/// corner, title and address. The dot's colour is never the only state
/// carrier: the row's semantics label says the word.
class FleetServerRow extends StatelessWidget {
  const FleetServerRow({super.key, required this.server, required this.fleet});

  final FleetServer server;
  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The status colours live on ghost_theme's chrome beside the tokens
    // they are held to the same contrast floor with.
    final chrome = GhostChrome.of(context, klabautermannThemeStyle);
    final phase = fleet.linkPhaseFor(server.id);
    final statusWord = linkPhaseWord(l10n, phase);
    final dot = switch (phase) {
      LinkPhase.connected => SidebarStatusDot(chrome.statusConnected),
      LinkPhase.connecting => SidebarStatusDot(chrome.statusConnecting),
      LinkPhase.failed => SidebarStatusDot(chrome.statusFailed),
      // Nothing observed yet paints no dot; the label still says the word.
      LinkPhase.disconnected => null,
    };
    return SidebarRow(
      mark: const Icon(Icons.dns_outlined),
      title: server.displayName,
      subtitle: server.address,
      status: dot,
      selected: fleet.selectedServerId == server.id,
      onActivate: (_) => fleet.select(server.id),
      semanticLabel: l10n.statusSemantics(statusWord),
    );
  }
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

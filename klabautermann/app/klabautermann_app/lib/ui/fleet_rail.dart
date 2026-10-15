import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'coverage.dart';
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
                // 03 §9.5 item 2: the fleet's coverage, over its section.
                FleetCoverageChip(fleet: widget.fleet),
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
    final status = fleet.linkStatusFor(server.id);
    final statusWord = linkStatusWord(l10n, status);
    final dot = switch (status) {
      LinkReady() || LinkDegraded() => SidebarStatusDot(chrome.statusConnected),
      LinkConnecting() ||
      LinkAuthenticating() ||
      LinkBackoff() => SidebarStatusDot(chrome.statusConnecting),
      // Waiting on the user, for a prompt or a decision, paints the
      // no-entry dot `ghost_servers` uses for "blocked".
      LinkNeedsUser() || LinkBlocked() => SidebarStatusDot(
        chrome.statusFailed,
        style: SidebarDotStyle.blocked,
      ),
      // Nothing observed yet, or a link closed on purpose with no failure
      // behind it, paints no dot; the label still says the word. Every
      // other close is failed: a failure kind names what the engine
      // classified, and a lost link is a failure its reason explains.
      LinkIdle() ||
      LinkClosed(reason: LinkClosedReason.closedByOwner, failure: null) => null,
      LinkClosed() => SidebarStatusDot(chrome.statusFailed),
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
    final invitation = Padding(
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
    // Centred while it fits, and scrolls when large text outgrows a short
    // column (A11Y-09), as under the phone's first-run card (03 §9.5).
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: invitation,
        ),
      ),
    );
  }
}

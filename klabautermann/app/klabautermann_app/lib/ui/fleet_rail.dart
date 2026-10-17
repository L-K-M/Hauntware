import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'coverage.dart';
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
                // 03 §9.5 item 2: the fleet's coverage, over its section.
                FleetCoverageChip(fleet: widget.fleet),
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
/// vocabulary (03 §10.3), used wherever the dot's colour needs words. A
/// closed link's failure is worded by [linkFailureText]; the other
/// reasons a status carries, by the surfaces that explain them.
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

/// What the engine found behind a closed link, with what to do about it,
/// or null for any other status and for a close it did not classify. The
/// server header shows it under its facts and the fleet row in its
/// tooltip and label. The client limitations keep 03 §5.3's words.
///
/// The two key-file kinds say to load the key into ssh-agent and drop
/// the `IdentityFile` line that names it: no prompt asks for a passphrase,
/// the Flatpak grants no key files (04 §12.1), and a server whose import
/// names a key file offers only that file (03 §2, proposals awaiting the
/// owner).
String? linkFailureText(AppLocalizations l10n, LinkStatus status) {
  if (status case LinkClosed(:final failure?)) {
    return switch (failure) {
      LinkFailureKind.unreachable => l10n.linkFailureUnreachable,
      LinkFailureKind.timedOut => l10n.linkFailureTimedOut,
      LinkFailureKind.authenticationRejected =>
        l10n.linkFailureAuthenticationRejected,
      LinkFailureKind.credentialUnavailable =>
        l10n.linkFailureCredentialUnavailable,
      LinkFailureKind.keyPassphraseRequired =>
        l10n.linkFailureKeyPassphraseRequired,
      LinkFailureKind.keyFileHiddenBySandbox =>
        l10n.linkFailureKeyFileHiddenBySandbox,
      LinkFailureKind.hostKeyDeclined => l10n.linkFailureHostKeyDeclined,
      LinkFailureKind.unsupportedAlgorithm =>
        l10n.linkFailureUnsupportedAlgorithm,
      LinkFailureKind.insecureAlgorithmsOnly =>
        l10n.linkFailureInsecureAlgorithmsOnly,
      LinkFailureKind.keyExchangeTimedOut =>
        l10n.linkFailureKeyExchangeTimedOut,
    };
  }
  return null;
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

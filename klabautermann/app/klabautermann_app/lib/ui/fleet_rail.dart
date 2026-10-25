import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../controllers/sync_controller.dart';
import '../l10n/app_localizations.dart';
import 'alerts.dart';
import 'coverage.dart';
import 'endpoint_confirmation.dart';
import 'fleet_rows.dart';
import 'sidebar_kit.dart';
import 'ssh_config_import_action.dart';
import 'sync_sign_in.dart';

/// The desktop rail of 03 §10.2: the coverage chip over the filter and the
/// fleet's sectioned rows ([FleetServerList]), and the kit's bottom bar
/// with the add menu, sync chip and settings gear.
class FleetRail extends StatelessWidget {
  const FleetRail({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.onOpenSettings,
    this.onAddServer,
    this.sync,
  });

  final FleetController fleet;

  /// Feeds the rows' pressure bars and freshness (03 §10.3).
  final MonitoringController monitoring;

  final VoidCallback onOpenSettings;

  /// The add-server entry point; null renders the menu verb disabled
  /// (enrollment lands with F3's catalog).
  final VoidCallback? onAddServer;

  /// The sync account behind the bottom bar's chip (03 §4.3): its action
  /// signs in, or runs a round once signed in. Null shows the chip idle.
  final SyncController? sync;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tokens = SidebarThemeTokens.of(context);
    return SidebarKitScope(
      strings: klabautermannSidebarStrings(l10n),
      child: ColoredBox(
        color: tokens.sidebarBackground,
        child: ListenableBuilder(
          listenable: Listenable.merge([fleet, sync]),
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 03 §9.5 item 2: the fleet's coverage, over its sections.
                FleetCoverageChip(fleet: fleet),
                Expanded(
                  child: FleetServerList(
                    fleet: fleet,
                    monitoring: monitoring,
                    showSelection: true,
                    onOpen: (server) => fleet.select(server.id),
                    // The raised alerts (ALR-01), then 03 §4.3 step 3's
                    // synced servers waiting to be confirmed.
                    header: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AlertsNotice(
                          fleet: fleet,
                          onOpenServer: (server) => fleet.select(server.id),
                        ),
                        EndpointsPendingNotice(fleet: fleet),
                      ],
                    ),
                  ),
                ),
                SidebarBottomBar(
                  addEntries: () => [
                    SidebarMenuAction(
                      label: l10n.addServer,
                      onSelected: onAddServer,
                    ),
                    // FL-02: desktops only; phones have no ssh_config.
                    if (fleet.canImportSshConfig)
                      SidebarMenuAction(
                        label: l10n.importSshConfig,
                        onSelected: fleet.isImportingSshConfig
                            ? null
                            : () => importSshConfigWithFeedback(context, fleet),
                      ),
                  ],
                  sync: _syncChip(context, l10n, sync),
                  onSettings: onOpenSettings,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The bottom bar's sync chip: muted until signed in, busy while a sign-in
/// or round runs.
SidebarSyncChipData _syncChip(
  BuildContext context,
  AppLocalizations l10n,
  SyncController? sync,
) {
  if (sync == null) {
    return SidebarSyncChipData(
      label: l10n.syncFleet,
      tone: SidebarSyncTone.muted,
    );
  }
  return SidebarSyncChipData(
    label: l10n.syncFleet,
    tone: switch (sync) {
      SyncController(busy: true) => SidebarSyncTone.busy,
      SyncController(needsSignIn: true) => SidebarSyncTone.muted,
      _ => SidebarSyncTone.normal,
    },
    tooltip: syncActionTooltip(l10n, sync),
    onPressed: () => runSyncAction(context, sync),
  );
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
      LinkFailureKind.keyboardInteractiveCancelled =>
        l10n.linkFailureKeyboardInteractiveCancelled,
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

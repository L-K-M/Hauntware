import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../../controllers/sync_sign_out.dart';
import '../../l10n/app_localizations.dart';

/// The Sync tab's account section (03 §4.3): the enrolled account and its
/// sign-out, which Poltergeist's matches. Nothing while no account is
/// enrolled.
class SyncSignOutSection extends StatelessWidget {
  const SyncSignOutSection({super.key, required this.model});

  final SyncSignOutSettings model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final account = model.account;
      if (account == null) return const SizedBox.shrink();

      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.settingsSyncAccountTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          Text(l10n.settingsSyncAccount(account.username, account.baseUrl)),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: model.busy ? null : () => unawaited(_signOut(context)),
              child: Text(l10n.settingsSyncSignOut),
            ),
          ),
        ],
      );
    },
  );

  /// Asks first, saying which connections close, then signs out; a
  /// failure shows a toast and leaves the account as it was.
  Future<void> _signOut(BuildContext context) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    final int open;
    try {
      open = await model.openConnectionsRemoved();
    } on Exception catch (error) {
      // Without the count the confirmation could not warn, so nothing runs.
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsSyncSignOutFailed);
      }
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settingsSyncSignOutTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.settingsSyncSignOutBody),
            if (open > 0) ...[
              const SizedBox(height: 12),
              Text(
                l10n.settingsSyncSignOutOpenConnections(open),
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.settingsSyncSignOutCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsSyncSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await model.signOut();
    } on SyncSignOutFailedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsSyncSignOutFailed);
      }
    }
  }
}

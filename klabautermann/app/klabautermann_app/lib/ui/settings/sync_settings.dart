import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, showTopToast;

import '../../controllers/account_size.dart';
import '../../controllers/pin_publication_controller.dart';
import '../../controllers/recovery_controller.dart';
import '../../controllers/sync_controller.dart' show PinConflictsSettings;
import '../../controllers/sync_secrets_controller.dart';
import '../../controllers/sync_sign_out.dart' show SyncSignOutSettings;
import '../../l10n/app_localizations.dart';
import '../pin_conflict_card.dart';
import 'recovery_settings.dart';
import 'setting_write.dart';
import 'sync_sign_out_section.dart';

/// The Sync tab: the device's "sync passwords" switch (03 §4.5, SYN-02),
/// in Séance's words. While on, sync rounds add the passwords and keys
/// other devices synced to this device's vault. Once a release is offered,
/// the host key sharing assertion too (D15, M5 plan M07).
/// SYN-09's account size view: what Klabautermann's records take of
/// their budget, with a warning near and at it, and every prefix's
/// records and bytes, the largest first.
class _AccountSizeSection extends StatelessWidget {
  const _AccountSizeSection({required this.size});

  final AccountSize size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final warning = size.full
        ? l10n.settingsAccountSizeFull
        : size.warns
        ? l10n.settingsAccountSizeWarn
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.settingsAccountSizeTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.settingsAccountSizeUsed(
            ghostFormatBinarySize(size.prefixBytes),
            ghostFormatBinarySize(size.budgetBytes),
          ),
        ),
        if (warning != null) ...[
          const SizedBox(height: 4),
          Text(
            warning,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          l10n.settingsAccountSizeDetail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (final row in size.rows)
          MergeSemantics(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(row.prefix),
              // Under the prefix rather than beside it: a trailing figure
              // takes its full width and overflows a narrow window at
              // large text (A11Y-09).
              subtitle: Text(
                l10n.settingsAccountSizeRow(
                  row.records,
                  ghostFormatBinarySize(row.bytes),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SyncTab extends StatelessWidget {
  const SyncTab({
    super.key,
    required this.syncSecrets,
    this.pinPublication,
    this.pinConflicts,
    this.accountSize,
    this.recovery,
    this.signOut,
  });

  final SyncSecretsSettings syncSecrets;
  final PinPublicationSettings? pinPublication;

  /// The host-key quarantine diff (03 §4.9); null in tests that leave it
  /// out, where the tab shows no conflict cards.
  final PinConflictsSettings? pinConflicts;

  /// As [SettingsPage.accountSize].
  final ValueListenable<AccountSize?>? accountSize;

  /// CRED-05's Recovery section, shown whether or not a sync account is
  /// enrolled; null in tests that leave it out.
  final RecoverySettings? recovery;

  /// As [SettingsPage.signOut].
  final SyncSignOutSettings? signOut;

  /// As [_set], for the host key sharing switch.
  Future<void> _assert(BuildContext context, bool asserted) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await pinPublication!.setAsserted(asserted);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsPinPublicationNotChanged);
      }
    }
  }

  /// As [GeneralTab._set].
  Future<void> _set(BuildContext context, bool enabled) async {
    await writeSetting<SyncSecretsNotSavedException>(
      context,
      () => syncSecrets.setSyncSecrets(enabled),
      notSaved: (l10n) => l10n.settingsSyncSecretsNotSaved,
      notChanged: (l10n) => l10n.settingsSyncSecretsNotChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pins = pinPublication;
    final recovery = this.recovery;
    final conflicts = pinConflicts;
    return ListenableBuilder(
      listenable: Listenable.merge([
        syncSecrets,
        ?pins,
        ?conflicts,
        ?accountSize,
        ?recovery,
        ?signOut,
      ]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (conflicts != null && conflicts.conflicts.isNotEmpty) ...[
            for (final conflict in conflicts.conflicts)
              PinConflictCard(conflict: conflict, settings: conflicts),
            const SizedBox(height: 24),
          ],
          if (signOut case final signOut? when signOut.account != null) ...[
            SyncSignOutSection(model: signOut),
            const SizedBox(height: 24),
          ],
          Semantics(
            header: true,
            child: Text(
              l10n.settingsSyncSecretsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: syncSecrets.value,
            onChanged: (enabled) => unawaited(_set(context, enabled)),
            title: Text(l10n.settingsSyncSecrets),
            subtitle: Text(l10n.settingsSyncSecretsDetail),
          ),
          if (pins?.value case PinPublication(
            :final release?,
            :final asserted,
          )) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsPinPublicationTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: asserted,
              onChanged: (value) => unawaited(_assert(context, value)),
              title: Text(l10n.settingsPinPublication(release)),
              subtitle: Text(l10n.settingsPinPublicationDetail),
            ),
          ],
          if (accountSize?.value case final size?) ...[
            const SizedBox(height: 24),
            _AccountSizeSection(size: size),
          ],
          if (recovery case final recovery?) ...[
            const SizedBox(height: 24),
            RecoverySection(model: recovery),
          ],
        ],
      ),
    );
  }
}

// Settings → Backup → Recovery (CRED-05): a code the user writes down,
// an encrypted export of this device's passwords and keys, and restoring
// one here. The section shows whether or not this device has a code, and
// whether or not the backup account is enrolled. The store-level crypto
// is seance_core's VaultRecovery through the app's SecretsRecovery; the
// section and its dialogs are ghost_ui's, worded from the ARB catalog.
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/secrets_recovery.dart';
import '../../services/settings_models.dart';
import '../../theme/app_theme.dart' show poltergeistMonoTextStyle;

/// The Recovery section's live state and actions, over [RecoverySettingsModel].
class RecoverySection extends StatelessWidget {
  const RecoverySection({super.key, required this.model});

  final RecoverySettingsModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostRecoverySection<RestoreConflictPolicy, SecretsRestoreSummary>(
      model: model,
      strings: _recoveryStrings(l10n),
      codeStyle: poltergeistMonoTextStyle,
      keepExisting: RestoreConflictPolicy.keepExisting,
      replaceExisting: RestoreConflictPolicy.replaceExisting,
      describeError: (error) => switch (error) {
        SecretsExportException(:final failure) => secretsExportFailureMessage(
          failure,
          l10n,
        ),
        RecoveryStatusException() => l10n.recoveryStatusFailed,
        _ => l10n.recoveryFailed,
      },
      describeStatusError: (_) => l10n.recoveryStatusFailed,
      describeSaveError: (_) => l10n.recoveryFailed,
      describeRestore: (summary) => _describeRestore(l10n, summary),
    );
  }
}

String _describeRestore(AppLocalizations l10n, SecretsRestoreSummary summary) {
  final parts = [
    l10n.recoveryRestoreAdded(summary.added),
    l10n.recoveryRestoreReplaced(summary.replaced),
    l10n.recoveryRestoreKept(summary.kept),
    if (summary.unreadable > 0)
      l10n.recoveryRestoreUnreadable(summary.unreadable),
  ];
  return l10n.recoveryRestoreSummary(parts.join(', '));
}

GhostRecoveryCodeStrings _codeStrings(AppLocalizations l10n) =>
    GhostRecoveryCodeStrings(
      title: l10n.recoveryCodeTitle,
      body: l10n.recoveryCodeBody,
      copy: l10n.recoveryCodeCopy,
      copied: l10n.recoveryCodeCopied,
      confirmLabel: l10n.recoveryCodeConfirmLabel,
      cancel: l10n.recoveryCodeCancel,
      done: l10n.recoveryCodeDone,
    );

GhostRecoveryStrings _recoveryStrings(AppLocalizations l10n) =>
    GhostRecoveryStrings(
      title: l10n.recoveryTitle,
      description: l10n.recoveryDescription,
      checking: l10n.recoveryChecking,
      configured: l10n.recoveryConfigured,
      notConfigured: l10n.recoveryNotConfigured,
      retry: l10n.recoveryRetry,
      setUp: l10n.recoverySetUp,
      replace: l10n.recoveryReplace,
      export: l10n.recoveryExport,
      restore: l10n.recoveryRestore,
      replaceTitle: l10n.recoveryReplaceTitle,
      replaceBody: l10n.recoveryReplaceBody,
      replaceCancel: l10n.recoveryCancel,
      replaceConfirm: l10n.recoveryReplaceConfirm,
      exportDone: l10n.recoveryExportDone,
      code: _codeStrings(l10n),
      restoreDialog: GhostRestoreDialogStrings(
        title: l10n.recoveryRestoreTitle,
        body: l10n.recoveryRestoreBody,
        codeLabel: l10n.recoveryRestoreCodeLabel,
        conflictLabel: l10n.recoveryRestoreConflictLabel,
        keep: l10n.recoveryRestoreKeep,
        replace: l10n.recoveryRestoreReplace,
        cancel: l10n.recoveryCancel,
        choose: l10n.recoveryRestoreChoose,
      ),
    );

/// Shows a new recovery code once and keeps it, through [save], only
/// after the user retypes its first group (ghost_ui's
/// [showGhostRecoveryCodeDialog]). True when the code was kept.
Future<bool> showRecoveryCodeDialog(
  BuildContext context,
  String code, {
  required Future<void> Function() save,
}) {
  final l10n = AppLocalizations.of(context);
  return showGhostRecoveryCodeDialog(
    context,
    code,
    save: save,
    strings: _codeStrings(l10n),
    codeStyle: poltergeistMonoTextStyle,
    describeSaveError: (_) => l10n.recoveryFailed,
  );
}

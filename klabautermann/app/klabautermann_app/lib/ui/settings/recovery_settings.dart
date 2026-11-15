// Settings → Sync → Recovery (CRED-05): a code the user writes down, an
// encrypted export of this device's passwords and keys, and restoring
// one here. The section shows whether or not this device has a code,
// whether or not a sync account is enrolled. The vault-level crypto is
// the engine's, over the app's RecoveryController; the section and its
// dialogs are ghost_ui's, worded from the ARB catalog.
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/recovery_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../services/recovery_files.dart';
import '../../theme/app_theme.dart' show klabautermannMonoStyle;

/// The Recovery section's live state and actions, over [RecoverySettings].
class RecoverySection extends StatelessWidget {
  const RecoverySection({super.key, required this.model});

  final RecoverySettings model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String describeError(Object error) => switch (error) {
      RecoveryException(:final failure) => recoveryFailureMessage(
        failure,
        l10n,
      ),
      RecoveryFileException(:final failure) => recoveryFileFailureMessage(
        failure,
        l10n,
      ),
      _ => l10n.recoveryFailed,
    };
    return GhostRecoverySection<VaultRestorePolicy, SecretsRestoreSummary>(
      model: model,
      strings: _recoveryStrings(l10n),
      codeStyle: klabautermannMonoStyle,
      keepExisting: VaultRestorePolicy.keepExisting,
      replaceExisting: VaultRestorePolicy.replaceExisting,
      describeError: describeError,
      describeStatusError: (error) => error is RecoveryException
          ? describeError(error)
          : l10n.recoveryStatusFailed,
      describeSaveError: describeError,
      describeRestore: (summary) {
        final parts = [
          l10n.recoveryRestoreAdded(summary.added),
          l10n.recoveryRestoreReplaced(summary.replaced),
          l10n.recoveryRestoreKept(summary.kept),
          if (summary.unreadable > 0)
            l10n.recoveryRestoreUnreadable(summary.unreadable),
        ];
        return l10n.recoveryRestoreSummary(parts.join(', '));
      },
    );
  }
}

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
      code: GhostRecoveryCodeStrings(
        title: l10n.recoveryCodeTitle,
        body: l10n.recoveryCodeBody,
        copy: l10n.recoveryCodeCopy,
        copied: l10n.recoveryCodeCopied,
        confirmLabel: l10n.recoveryCodeConfirmLabel,
        cancel: l10n.recoveryCodeCancel,
        done: l10n.recoveryCodeDone,
      ),
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

/// The engine's fixed recovery failure as its ARB sentence. Each kind is
/// actionable on its own; no diagnostic text crosses.
String recoveryFailureMessage(
  VaultRecoveryFailure failure,
  AppLocalizations l10n,
) => switch (failure) {
  VaultRecoveryFailure.directoryShared => l10n.recoveryDirectoryShared,
  VaultRecoveryFailure.keystoreUnavailable => l10n.recoveryKeystoreUnavailable,
  VaultRecoveryFailure.notSetUp => l10n.recoveryNotSetUp,
  VaultRecoveryFailure.damaged => l10n.recoveryDamaged,
  VaultRecoveryFailure.invalidCode => l10n.recoveryInvalidCode,
  VaultRecoveryFailure.wrongCode => l10n.recoveryWrongCode,
  VaultRecoveryFailure.tampered => l10n.recoveryTampered,
  VaultRecoveryFailure.malformed => l10n.recoveryMalformed,
  VaultRecoveryFailure.unsupportedVersion => l10n.recoveryUnsupportedVersion,
  VaultRecoveryFailure.tooLarge => l10n.recoveryTooLarge,
  VaultRecoveryFailure.failed => l10n.recoveryFailed,
};

/// A recovery export file failure as its ARB sentence.
String recoveryFileFailureMessage(
  RecoveryFileFailure failure,
  AppLocalizations l10n,
) => switch (failure) {
  RecoveryFileFailure.tooLarge => l10n.recoveryFileTooLarge,
  RecoveryFileFailure.unreadable => l10n.recoveryFileUnreadable,
  RecoveryFileFailure.saveFailed => l10n.recoveryFileSaveFailed,
};

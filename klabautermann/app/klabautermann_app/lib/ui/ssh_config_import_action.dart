import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import '../services/ssh_config_source.dart';

/// Runs the FL-02 import and reports how it ended in a top toast, so every
/// outcome, a missing or unreadable file included, ends in words rather
/// than silence. A toast rather than a snack bar: the suite keeps the
/// bottom edge clear, where the rail's add and settings buttons sit.
/// Both shells' import entries call this.
Future<void> importSshConfigWithFeedback(
  BuildContext context,
  FleetController fleet,
) async {
  // Captured before the await: the entry that started the import may be
  // gone by then, and the root overlay outlives it.
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);

  final outcome = await fleet.importSshConfig();
  if (!overlay.mounted) return;
  showTopToast(overlay, message: sshConfigImportMessage(l10n, outcome));
}

/// The user-facing sentence for [outcome].
String sshConfigImportMessage(
  AppLocalizations l10n,
  SshConfigImportOutcome outcome,
) {
  return switch (outcome) {
    SshConfigImportSucceeded(:final importedCount, skippedCount: 0) =>
      l10n.sshConfigImported(importedCount),
    // One message for both counts: "names no hosts" would contradict the
    // skipped hosts, and the translation owns how the sentences join.
    SshConfigImportSucceeded(:final importedCount, :final skippedCount) =>
      l10n.sshConfigImportedWithSkips(importedCount, skippedCount),
    SshConfigImportUnreadable(failure: SshConfigReadFailure.missing) =>
      l10n.sshConfigMissing,
    SshConfigImportUnreadable(failure: SshConfigReadFailure.unreadable) =>
      l10n.sshConfigUnreadable,
    SshConfigImportUnreadable(failure: SshConfigReadFailure.tooLarge) =>
      l10n.sshConfigTooLarge,
    SshConfigImportRejected() => l10n.sshConfigImportFailed,
  };
}

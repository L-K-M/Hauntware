// CRED-05's enrolment prompt: after a credential is saved on a device
// that has no recovery code, the code is offered once. "Not now" is
// remembered and the offer is not made again; Settings → Backup →
// Recovery still makes it. Dismissing the dialog without answering
// leaves the offer for the next save.
import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/recovery_settings.dart';
import 'settings/recovery_settings.dart';
import 'top_toast.dart';

/// Offers a recovery code after a credential is saved, following the
/// same semantics as Séance's enrolment prompt.
Future<void> offerRecoveryCode(
  BuildContext context,
  RecoverySettings recovery,
) async {
  if (recovery.promptDeclined) return;
  final bool configured;
  try {
    configured = await recovery.recoveryConfigured();
  } on Object {
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context);
    showTopToastIn(
      context,
      message: l10n.recoveryPromptFailed,
      actionLabel: l10n.recoveryPromptRetry,
      onAction: () {
        if (context.mounted) unawaited(offerRecoveryCode(context, recovery));
      },
    );
    return;
  }
  if (configured || !context.mounted) return;

  final l10n = AppLocalizations.of(context);
  final setUp = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.recoveryPromptTitle),
      content: Text(l10n.recoveryPromptBody),
      actions: [
        TextButton(
          key: const ValueKey('recovery.prompt.notNow'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.recoveryPromptNotNow),
        ),
        FilledButton(
          key: const ValueKey('recovery.prompt.setUp'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.recoveryPromptSetUp),
        ),
      ],
    ),
  );
  if (setUp == null) return;
  if (!setUp) {
    try {
      await recovery.declinePrompt();
    } on Object catch (error) {
      if (context.mounted) {
        showTopToastIn(
          context,
          message: l10n.recoveryPromptDeclineFailed('$error'),
        );
      }
    }
    return;
  }
  if (!context.mounted) return;
  final code = await recovery.newCode();
  if (!context.mounted) return;
  await showRecoveryCodeDialog(
    context,
    code,
    save: () => recovery.saveCode(code),
  );
}

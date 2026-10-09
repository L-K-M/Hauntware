import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/app_lock.dart';
import 'recovery_settings.dart';
import 'top_toast.dart';

/// Offers a recovery code after a credential is saved on a device that has
/// none (CRED-05's enrolment prompt). "Not now" is remembered and the offer
/// is not made again; Settings > Sync > Recovery still makes it. Dismissing
/// the dialog without answering leaves the offer for the next save.
Future<void> offerRecoveryCode(BuildContext context, AppState state) async {
  if (state.services.settings.recoveryPromptDeclined) return;
  try {
    if (await state.recoveryConfigured() || !context.mounted) return;
  } on AppLockException catch (error) {
    if (context.mounted) {
      showTopToastIn(
        context,
        message: error.message,
        actionLabel: 'Retry',
        onAction: () {
          if (context.mounted) unawaited(offerRecoveryCode(context, state));
        },
      );
    }
    return;
  }

  final setUp = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Set up a recovery code?'),
      content: const Text(
        'Passwords and keys saved here stay on this device unless you sync '
        'them. A recovery code lets you export them, encrypted, and restore '
        'them on another device, or on this one after a reinstall.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('recovery.prompt.notNow'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const ValueKey('recovery.prompt.setUp'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Set up…'),
        ),
      ],
    ),
  );
  if (setUp == null) return;
  if (!setUp) {
    try {
      await state.declineRecoveryPrompt();
    } catch (e) {
      if (context.mounted) {
        showTopToastIn(context, message: 'Could not save your answer: $e');
      }
    }
    return;
  }
  if (!context.mounted) return;
  final code = state.newRecoveryCode();
  await showRecoveryCodeDialog(
    context,
    code,
    save: () => state.saveRecoveryCode(code),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/alert_notifications.dart';
import '../l10n/app_localizations.dart';

/// Hands the [AlertNotificationsController] to the alert surfaces; without
/// one, as in tests that leave it out, no notification switch shows.
class AlertNotificationsScope
    extends InheritedNotifier<AlertNotificationsController> {
  const AlertNotificationsScope({
    super.key,
    required AlertNotificationsController notifications,
    required super.child,
  }) : super(notifier: notifications);

  static AlertNotificationsController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AlertNotificationsScope>()
      ?.notifier;
}

/// The switch for raised alerts' system notifications (ALR-01). Turning it
/// on first says, in the app's prompt before the system's, that rules are
/// evaluated on this device while Klabautermann is open (Y3). Nothing
/// without an [AlertNotificationsScope] or where the device has no
/// notifications to post.
class AlertNotificationsSwitch extends StatelessWidget {
  const AlertNotificationsSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final notifications = AlertNotificationsScope.maybeOf(context);
    if (notifications == null || !notifications.available) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return SwitchListTile(
      value: notifications.enabled,
      title: Text(l10n.alertNotificationsSwitch),
      subtitle: Text(l10n.alertNotificationsSwitchDetail),
      onChanged: (on) => unawaited(_set(context, notifications, on)),
    );
  }

  Future<void> _set(
    BuildContext context,
    AlertNotificationsController notifications,
    bool on,
  ) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context);
    if (on && !await _confirm(context)) return;

    String? notice;
    try {
      notice = switch (await notifications.setEnabled(on)) {
        AlertNotificationsOutcome.enabled => null,
        AlertNotificationsOutcome.denied => l10n.alertNotificationsDenied,
        AlertNotificationsOutcome.unavailable =>
          l10n.alertNotificationsUnavailable,
      };
    } on Object {
      notice = l10n.alertNotificationsNotSaved;
    }
    if (notice != null && overlay.mounted) {
      showTopToast(overlay, message: notice);
    }
  }

  static Future<bool> _confirm(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final allowed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.alertNotificationsPromptTitle),
        content: Text(l10n.alertNotificationsPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.alertNotificationsPromptLater),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.alertNotificationsPromptAllow),
          ),
        ],
      ),
    );
    return allowed ?? false;
  }
}

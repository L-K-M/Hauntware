import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show appLockBackgroundTimeout;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/app_lock_controller.dart';
import '../l10n/app_localizations.dart';

/// Settings > Safety's app lock switch (SAF-20). Turning it on or off asks
/// for device authentication first; a change that did not take says why.
/// Off and disabled where the platform has no system prompt.
class AppLockSection extends StatelessWidget {
  const AppLockSection({super.key, required this.lock});

  final AppLockSettings lock;

  Future<void> _set(BuildContext context, bool enabled) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    String reason;
    try {
      final change = await lock.setEnabled(enabled);
      if (change == AppLockChange.changed) return;
      reason = change.name;
    } on Exception catch (error) {
      // The settings window lost the app, or the change failed some
      // other way: nothing changed.
      debugPrint('$error');
      reason = '';
    }
    if (!overlay.mounted) return;
    showTopToast(overlay, message: l10n.settingsAppLockNotChanged(reason));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        final support = lock.support;
        final note = switch (support) {
          AppLockSupport.unsupported => l10n.settingsAppLockUnsupported,
          AppLockSupport.unavailable => l10n.settingsAppLockUnavailable,
          AppLockSupport.available => null,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.settingsAppLockTitle,
                style: textTheme.titleSmall,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: lock.enabled,
              onChanged: support == AppLockSupport.unsupported
                  ? null
                  : (enabled) => unawaited(_set(context, enabled)),
              title: Text(l10n.settingsAppLock),
              subtitle: Text(
                [
                  l10n.settingsAppLockDetail(
                    appLockBackgroundTimeout.inMinutes,
                  ),
                  ?note,
                ].join('\n'),
              ),
            ),
          ],
        );
      },
    );
  }
}

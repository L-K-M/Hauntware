import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import 'app_lock.dart' show appLockBackgroundTimeout;
import 'app_lock_controller.dart';

/// [GhostAppLockSection]'s strings, in the app's own words and language.
final class GhostAppLockSectionStrings {
  const GhostAppLockSectionStrings({
    required this.title,
    required this.toggle,
    required this.detail,
    required this.unsupported,
    required this.unavailable,
    required this.notChanged,
  });

  /// The heading over the switch.
  final String title;

  /// The switch's label.
  final String toggle;

  /// What the switch does, locking after `minutes` in the background.
  final String Function(int minutes) detail;

  /// Why the switch is off and disabled: no system prompt (Linux).
  final String unsupported;

  /// Why the switch cannot be turned on now: no passcode, PIN or
  /// biometrics set up.
  final String unavailable;

  /// The toast after a change did not take effect, by `change`; null when
  /// it failed some other way, such as the Settings window losing the app.
  final String Function(AppLockChange? change) notChanged;
}

/// Settings' app lock switch (Poltergeist cred-05, Klabautermann SAF-20)
/// over [lock]. Turning it on or off asks for device authentication
/// first; a change that did not take says why in a toast. Off and
/// disabled where the platform has no system prompt.
class GhostAppLockSection extends StatelessWidget {
  const GhostAppLockSection({
    super.key,
    required this.lock,
    required this.strings,
  });

  final AppLockSettings lock;
  final GhostAppLockSectionStrings strings;

  Future<void> _set(BuildContext context, bool enabled) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    AppLockChange? reason;
    try {
      final change = await lock.setEnabled(enabled);
      if (change == AppLockChange.changed) return;
      reason = change;
    } on Exception catch (error) {
      // The settings window lost the app, or the change failed some
      // other way: nothing changed.
      debugPrint('$error');
    }
    if (!overlay.mounted) return;
    showTopToast(overlay, message: strings.notChanged(reason));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        final support = lock.support;
        final note = switch (support) {
          AppLockSupport.unsupported => strings.unsupported,
          AppLockSupport.unavailable => strings.unavailable,
          AppLockSupport.available => null,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(strings.title, style: textTheme.titleSmall),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: lock.enabled,
              onChanged: support == AppLockSupport.unsupported
                  ? null
                  : (enabled) => unawaited(_set(context, enabled)),
              title: Text(strings.toggle),
              subtitle: Text(
                [
                  strings.detail(appLockBackgroundTimeout.inMinutes),
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

import 'package:flutter/material.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show AppLockSettings, GhostAppLockSection, GhostAppLockSectionStrings;

import '../../l10n/app_localizations.dart';

/// Settings > General's app lock switch (cred-05): ghost_keystore's
/// [GhostAppLockSection], worded from the ARB catalog.
class AppLockSection extends StatelessWidget {
  const AppLockSection({super.key, required this.lock});

  final AppLockSettings lock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostAppLockSection(
      lock: lock,
      strings: GhostAppLockSectionStrings(
        title: l10n.settingsAppLockTitle,
        toggle: l10n.settingsAppLock,
        detail: l10n.settingsAppLockDetail,
        unsupported: l10n.settingsAppLockUnsupported,
        unavailable: l10n.settingsAppLockUnavailable,
        notChanged: (change) =>
            l10n.settingsAppLockNotChanged(change?.name ?? ''),
      ),
    );
  }
}

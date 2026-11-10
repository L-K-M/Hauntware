import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/sync_controller.dart' show PinConflictsSettings;
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart' show klabautermannMonoStyle;

/// One host-key conflict in Settings > Sync (03 §4.9): the warning, both
/// fingerprints, and the two resolutions, as Poltergeist's enrolled view
/// shows them. The buttons stay disabled while [settings] is resolving, so a
/// double tap cannot send two requests.
class PinConflictCard extends StatelessWidget {
  const PinConflictCard({
    super.key,
    required this.conflict,
    required this.settings,
  });

  final SyncPinConflict conflict;
  final PinConflictsSettings settings;

  Future<void> _resolve(BuildContext context, bool keepLocal) async {
    // Captured first: the card may leave once the resolution applies.
    final overlay = Overlay.of(context, rootOverlay: true);
    final notResolved = AppLocalizations.of(
      context,
    ).settingsPinConflictNotResolved;
    try {
      await settings.resolvePinConflict(conflict, keepLocal: keepLocal);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notResolved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mono = klabautermannMonoStyle.copyWith(
      fontSize: theme.textTheme.bodySmall?.fontSize,
    );
    return Card.outlined(
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsPinConflictWarning(conflict.locator),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(l10n.settingsPinLocalKey),
            SelectableText(conflict.localFingerprintSha256, style: mono),
            const SizedBox(height: 4),
            Text(l10n.settingsPinPulledKey),
            SelectableText(conflict.pulledFingerprintSha256, style: mono),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  key: ValueKey('settings.pin.keep.${conflict.locator}'),
                  onPressed: settings.resolving
                      ? null
                      : () => unawaited(_resolve(context, true)),
                  child: Text(l10n.settingsPinKeepLocal),
                ),
                TextButton(
                  key: ValueKey('settings.pin.accept.${conflict.locator}'),
                  onPressed: settings.resolving
                      ? null
                      : () => unawaited(_resolve(context, false)),
                  child: Text(l10n.hostKeyTrustNewKey),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

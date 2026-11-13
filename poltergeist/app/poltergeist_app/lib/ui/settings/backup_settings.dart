// The Settings → Backup surface (04 §4.3): one section widget that swaps
// between the enrollment form and the enrolled view on the service's
// account state, plus the dialog the `open-settings-backup` command
// raises. 02 §10's full five-tab Settings screen is a later slice — this
// dialog is the Backup section's bounded mount, titled "Settings" so the
// surface reads as the spec's "Settings → Backup".
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/settings_models.dart';
import '../../services/sync_account_gate.dart';
import 'backup_enrolled_view.dart';
import 'backup_enrollment_form.dart';
import 'recovery_settings.dart';

/// The Bookmark backup section, unenrolled or enrolled by the service's
/// durable account state, followed by CRED-05's Recovery section —
/// available whether or not this device has a backup account or a
/// recovery code.
final class BackupSettingsSection extends StatelessWidget {
  const BackupSettingsSection({
    super.key,
    required this.service,
    this.recovery,
    this.gate = const SyncAccountGate.production(),
  });

  final BackupSettingsModel service;
  final RecoverySettingsModel? recovery;
  final SyncAccountGate gate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: service,
          builder: (context, _) => service.account == null
              ? BackupEnrollmentForm(service: service, gate: gate)
              : BackupEnrolledView(service: service, gate: gate),
        ),
        if (recovery != null) ...[
          const SizedBox(height: 24),
          RecoverySection(model: recovery!),
        ],
      ],
    );
  }
}

/// The `open-settings-backup` command's surface: a dialog carrying just
/// the Backup section until the full Settings screen lands.
Future<void> showBackupSettingsDialog(
  BuildContext context, {
  required BackupSettingsModel service,
  RecoverySettingsModel? recovery,
  SyncAccountGate gate = const SyncAccountGate.production(),
}) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          key: const ValueKey('backup.settings.dialog'),
          title: Text(l10n.settingsTitle),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: BackupSettingsSection(
                service: service,
                recovery: recovery,
                gate: gate,
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('backup.settings.close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.backupClose),
            ),
          ],
        );
      },
    );

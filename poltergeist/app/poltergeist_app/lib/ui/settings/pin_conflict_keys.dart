import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// The two host keys of a quarantined pin, the one this device trusts and
/// the one sync brought, so the choice between them can be checked against
/// the server's own fingerprint, as Séance's Settings ▸ Sync shows them
/// (#56). [pulledLabel] names where the other key came from.
class PinConflictKeys extends StatelessWidget {
  const PinConflictKeys({
    super.key,
    required this.conflict,
    required this.pulledLabel,
  });

  final HostKeyConflict conflict;
  final String pulledLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mono = poltergeistMonoTextStyle.copyWith(
      fontSize: Theme.of(context).textTheme.bodySmall?.fontSize,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.backupPinLocalKey),
          SelectableText(conflict.local.fingerprintSha256, style: mono),
          const SizedBox(height: 4),
          Text(pulledLabel),
          SelectableText(conflict.pulled.fingerprintSha256, style: mono),
        ],
      ),
    );
  }
}

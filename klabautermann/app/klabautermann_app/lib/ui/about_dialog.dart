import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The About dialog (M16, 04 §12.3): the app title with its preview label,
/// the version and the licence, over Material's dialog, whose View
/// licenses button lists the bundled packages' licences. The About command
/// opens it on every desktop, in place of AppKit's About panel on macOS,
/// and Settings > General's about row opens it everywhere.
void showAppAboutDialog(BuildContext context, {required String? version}) {
  final l10n = AppLocalizations.of(context);
  showAboutDialog(
    context: context,
    applicationName: l10n.appTitle,
    applicationVersion: appVersionLine(l10n, version),
    applicationLegalese: l10n.aboutLicence,
  );
}

/// The version as the About dialog and the about row word it; [version]
/// is null when the platform could not tell (`readAppVersion`).
String appVersionLine(AppLocalizations l10n, String? version) =>
    version == null ? l10n.aboutVersionUnknown : l10n.aboutVersion(version);

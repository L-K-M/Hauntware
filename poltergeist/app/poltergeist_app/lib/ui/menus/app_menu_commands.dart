import 'dart:async';

import 'package:flutter/material.dart' show showAboutDialog;
import 'package:flutter/widgets.dart';
import 'package:ghost_update/ghost_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../top_toast.dart';

/// The macOS application menu's manual update check (10 §8).
const kAppCheckForUpdatesCommandId = 'app.checkForUpdates';

/// The Linux/Windows File menu's Quit (10 §8).
const kAppQuitCommandId = 'app.quit';

/// Help ▸ About Poltergeist on Linux and Windows.
const kAppAboutCommandId = 'app.about';

/// 10 §8's "Check for Updates…": D19's link-only check, run on demand.
/// Register it on macOS only: the spec places it in the application
/// menu, ahead of Settings… (same group, lower order), and names no
/// other platform's row. Its [CommandMenuPlacement.menu] is therefore
/// only the non-Mac fallback the placement type requires.
///
/// A newer release is announced with a link to its page (it also lands
/// in Alerts); otherwise the toast says no newer version was found,
/// never "up to date": the checker cannot tell that from a check that
/// could not reach GitHub.
RegisteredCommand buildCheckForUpdatesCommand({
  required UpdateCheckController updates,
  required Future<void> Function(Uri url) openUrl,
  Future<String?> Function() currentVersion = _runningVersion,
}) {
  return RegisteredCommand(
    id: kAppCheckForUpdatesCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.appCheckForUpdatesLabel,
    run: (context) async {
      final l10n = AppLocalizations.of(context);
      final overlay = Overlay.of(context, rootOverlay: true);
      final version = await currentVersion();
      final info = version == null ? null : await updates.checkNow(version);
      if (!overlay.mounted) return;
      if (info == null) {
        showTopToast(overlay, message: l10n.appUpdateNoneFound);
        return;
      }
      showTopToast(
        overlay,
        message: l10n.alertUpdateAvailable(info.latestVersion),
        actionLabel: l10n.alertActionViewRelease,
        onAction: () => unawaited(openUrl(info.releasesUrl)),
      );
    },
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 165,
      group: 6,
      appMenuOnMac: true,
    ),
  );
}

/// 10 §8's File ▸ Quit for Linux and Windows, closing the menu in
/// Settings…'s group as the spec's table lists them. Register it there only:
/// macOS has AppKit's own Quit in the application menu, and a phone has
/// no quit at all.
///
/// It asks the window to close rather than destroying it. window_manager
/// intercepts that close (DesktopWindowLifecycle enables prevent-close)
/// and raises the same event as the titlebar's close button, so Quit
/// runs the one guarded path: the live-transfer warning, the session
/// flush, then destroy.
RegisteredCommand buildQuitCommand({Future<void> Function()? requestClose}) {
  return RegisteredCommand(
    id: kAppQuitCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.appQuitLabel,
    run: (_) => (requestClose ?? windowManager.close)(),
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 180,
      group: 6,
    ),
  );
}

/// Help ▸ About Poltergeist for Linux and Windows, where there is no
/// application menu: the About dialog Klabautermann's Help menu opens
/// there (name, version, legalese, and View licenses for every bundled
/// notice). Register it there only: macOS has AppKit's About row.
RegisteredCommand buildAboutCommand({required String? version}) {
  return RegisteredCommand(
    id: kAppAboutCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.appAboutLabel,
    run: (context) async {
      final l10n = AppLocalizations.of(context);
      showAboutDialog(
        context: context,
        applicationName: l10n.appTitle,
        applicationVersion: version,
        applicationLegalese: l10n.openSourceLicensesLegalese,
      );
    },
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.help,
      order: 40,
    ),
  );
}

Future<String?> _runningVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } on Object {
    return null;
  }
}

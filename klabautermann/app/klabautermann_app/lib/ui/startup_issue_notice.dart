import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DeviceSettingsIssue,
        DeviceSettingsIssueKind,
        ImportStoreIssue,
        ImportStoreIssueKind;

import '../l10n/app_localizations.dart';

/// Long enough to read a file name off the notice.
const Duration _noticeDuration = Duration(seconds: 10);

/// Tells the user once, after the first frame, what went wrong with the
/// device-local files when the app started: the app's `settings.json`
/// ([settingsIssue]) and the engine's `ssh_config_imports.json`
/// ([importStoreIssue]), as Séance does for its own settings file. A
/// silent reset, or changes that will not be kept, is not something to
/// leave the user to find out. Shows nothing when both are null.
class StartupIssueNotice extends StatefulWidget {
  const StartupIssueNotice({
    super.key,
    required this.settingsIssue,
    required this.importStoreIssue,
    required this.child,
  });

  final DeviceSettingsIssue? settingsIssue;
  final ImportStoreIssue? importStoreIssue;
  final Widget child;

  @override
  State<StartupIssueNotice> createState() => _StartupIssueNoticeState();
}

class _StartupIssueNoticeState extends State<StartupIssueNotice> {
  @override
  void initState() {
    super.initState();
    final settingsIssue = widget.settingsIssue;
    final importStoreIssue = widget.importStoreIssue;
    if (settingsIssue == null && importStoreIssue == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final overlay = Overlay.of(context, rootOverlay: true);
      // One toast each; the toast stack shows them together.
      for (final message in [
        if (settingsIssue != null) settingsIssueMessage(l10n, settingsIssue),
        if (importStoreIssue != null)
          importStoreIssueMessage(l10n, importStoreIssue),
      ]) {
        showTopToast(overlay, message: message, duration: _noticeDuration);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The user-facing sentence for a settings [issue].
String settingsIssueMessage(AppLocalizations l10n, DeviceSettingsIssue issue) {
  // The store sets where it kept the damaged file for the recovered kinds.
  String keptAs() => _fileName(issue.preservedAs!);

  return switch (issue.kind) {
    DeviceSettingsIssueKind.recovered => l10n.settingsFileRecovered(keptAs()),
    DeviceSettingsIssueKind.recoveredNotSaved =>
      l10n.settingsFileRecoveredNotSaved(keptAs()),
    DeviceSettingsIssueKind.unreadable ||
    DeviceSettingsIssueKind.unpreserved => l10n.settingsFileLeftAsIs,
    DeviceSettingsIssueKind.newerVersion => l10n.settingsFileNewer,
    DeviceSettingsIssueKind.notSaved => l10n.settingsFileNotSaved,
  };
}

/// The user-facing sentence for an import store [issue].
String importStoreIssueMessage(AppLocalizations l10n, ImportStoreIssue issue) {
  return switch (issue.kind) {
    // The engine sets where it kept the damaged file for this kind.
    ImportStoreIssueKind.recovered => l10n.importsFileRecovered(
      _fileName(issue.preservedAs!),
    ),
    ImportStoreIssueKind.leftAsIs => l10n.importsFileLeftAsIs,
    ImportStoreIssueKind.newerVersion => l10n.importsFileNewer,
  };
}

/// The last segment of [path], which names a kept file without the
/// support directory's long platform path.
String _fileName(String path) => File(path).uri.pathSegments.last;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DeviceSettingsIssue,
        DeviceSettingsIssueKind,
        ImportStoreIssue,
        ImportStoreIssueKind,
        InstanceLockUnavailable,
        SyncStoreIssue,
        SyncStoreIssueKind;

import '../l10n/app_localizations.dart';

/// Long enough to read a file name off the notice.
const Duration _noticeDuration = Duration(seconds: 10);

/// Tells the user once, after the first frame, what went wrong with the
/// device-local files when the app started: the app's `settings.json`
/// ([settingsIssue]), the engine's `ssh_config_imports.json`
/// ([importStoreIssue]), the engine's sync state files
/// ([syncStoreIssues]) and the instance lock ([instanceLockIssue]), as
/// Séance does for its own settings file. A silent reset, changes that
/// will not be kept, or a missing guard against a second instance is not
/// something to leave the user to find out. Shows nothing when there is
/// none.
class StartupIssueNotice extends StatefulWidget {
  const StartupIssueNotice({
    super.key,
    required this.settingsIssue,
    required this.importStoreIssue,
    this.syncStoreIssues = const [],
    required this.instanceLockIssue,
    required this.child,
  });

  final DeviceSettingsIssue? settingsIssue;
  final ImportStoreIssue? importStoreIssue;
  final List<SyncStoreIssue> syncStoreIssues;
  final InstanceLockUnavailable? instanceLockIssue;
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
    final syncStoreIssues = widget.syncStoreIssues;
    final instanceLockIssue = widget.instanceLockIssue;
    if (settingsIssue == null &&
        importStoreIssue == null &&
        syncStoreIssues.isEmpty &&
        instanceLockIssue == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final overlay = Overlay.of(context, rootOverlay: true);
      // One toast each; the toast stack shows them together.
      for (final message in [
        if (settingsIssue != null) settingsIssueMessage(l10n, settingsIssue),
        if (importStoreIssue != null)
          importStoreIssueMessage(l10n, importStoreIssue),
        for (final issue in syncStoreIssues) syncStoreIssueMessage(l10n, issue),
        if (instanceLockIssue != null) l10n.instanceLockUnavailable,
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

/// The user-facing sentence for a sync state file [issue].
String syncStoreIssueMessage(AppLocalizations l10n, SyncStoreIssue issue) {
  return switch (issue.kind) {
    // The engine sets where it kept the damaged file for this kind.
    SyncStoreIssueKind.recovered => l10n.syncFileRecovered(
      issue.fileName,
      _fileName(issue.preservedAs!),
    ),
    SyncStoreIssueKind.leftAsIs => l10n.syncFileLeftAsIs(issue.fileName),
    SyncStoreIssueKind.newerVersion => l10n.syncFileNewer(issue.fileName),
  };
}

/// The last segment of [path], which names a kept file without the
/// support directory's long platform path.
String _fileName(String path) => File(path).uri.pathSegments.last;

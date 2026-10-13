import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show DeviceSettingsIssue, DeviceSettingsIssueKind;

import '../l10n/app_localizations.dart';

/// Long enough to read a file name off the notice.
const Duration _noticeDuration = Duration(seconds: 10);

/// Tells the user once, after the first frame, what went wrong with
/// `settings.json` when the app opened it, as Séance does for its own
/// settings file: a silent reset, or changes that will not be kept, is not
/// something to leave them to find out. Shows nothing when [issue] is null.
class SettingsIssueNotice extends StatefulWidget {
  const SettingsIssueNotice({
    super.key,
    required this.issue,
    required this.child,
  });

  final DeviceSettingsIssue? issue;
  final Widget child;

  @override
  State<SettingsIssueNotice> createState() => _SettingsIssueNoticeState();
}

class _SettingsIssueNoticeState extends State<SettingsIssueNotice> {
  @override
  void initState() {
    super.initState();
    final issue = widget.issue;
    if (issue == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showTopToast(
        Overlay.of(context, rootOverlay: true),
        message: settingsIssueMessage(AppLocalizations.of(context), issue),
        duration: _noticeDuration,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The user-facing sentence for [issue].
String settingsIssueMessage(AppLocalizations l10n, DeviceSettingsIssue issue) {
  return switch (issue.kind) {
    // The store sets where it kept the damaged file for this kind.
    DeviceSettingsIssueKind.recovered => l10n.settingsFileRecovered(
      File(issue.preservedAs!).uri.pathSegments.last,
    ),
    DeviceSettingsIssueKind.unreadable ||
    DeviceSettingsIssueKind.unpreserved => l10n.settingsFileLeftAsIs,
    DeviceSettingsIssueKind.newerVersion => l10n.settingsFileNewer,
    DeviceSettingsIssueKind.notSaved => l10n.settingsFileNotSaved,
  };
}

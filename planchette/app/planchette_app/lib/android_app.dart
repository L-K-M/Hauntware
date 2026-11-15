import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart';

import 'planchette_app.dart';
import 'services/android_documents.dart';
import 'services/app_settings.dart';
import 'services/document_dialogs.dart';
import 'services/document_workspace.dart';
import 'services/session_journal.dart';

/// The phone owns one workspace and uses the system document provider. Desktop
/// window channels must never run before this app's first frame.
Future<void> runAndroidApp({String? appVersion}) async {
  final documents = AndroidDocuments();
  final settingsPath = await documents.settingsPath();
  final settings = SettingsController(
    store: LocalSettingsStore(File(settingsPath)),
  );
  await settings.load();
  // Beside the settings in the app's files folder, which is private and,
  // with backup off, never leaves the device.
  final journal = SessionJournal(
    store: SessionJournalStore(
      Directory(paths.join(paths.dirname(settingsPath), 'session')),
    ),
    settings: settings,
    onError: (workspace, error) => workspace.reportError(
      'Unsaved changes could not be kept for the next launch: $error',
    ),
  );
  final kept = await journal.open();
  final navigatorKey = GlobalKey<NavigatorState>();
  final workspace = DocumentWorkspace(
    store: documents,
    dialogs: AppDocumentDialogs(navigatorKey, android: documents),
    toolHistory: TextToolHistory.decode(settings.value.recentTextTools),
    recoveries: documents,
  );
  await journal.restoreWorkspace(workspace, kept);
  final recoveryPaths = await documents.recoveries();
  if (recoveryPaths.isNotEmpty) {
    await workspace.openAll(recoveryPaths);
  } else if (workspace.documents.isEmpty) {
    workspace.newDocument();
  }
  runApp(_AndroidApp(workspace, settings, journal, navigatorKey, appVersion));
}

class _AndroidApp extends StatefulWidget {
  const _AndroidApp(
    this.workspace,
    this.settings,
    this.journal,
    this.navigatorKey,
    this.appVersion,
  );

  final DocumentWorkspace workspace;
  final SettingsController settings;
  final SessionJournal journal;
  final GlobalKey<NavigatorState> navigatorKey;
  final String? appVersion;

  @override
  State<_AndroidApp> createState() => _AndroidAppState();
}

class _AndroidAppState extends State<_AndroidApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(widget.workspace.checkDisk()),
      onInactive: _keep,
      // Android may end a paused process without warning: what is open
      // must already be on disk.
      onPause: _keep,
      onHide: _keep,
    );
  }

  void _keep() {
    unawaited(widget.settings.flush());
    unawaited(widget.journal.flushAll());
  }

  Future<void> _quit() async {
    if (!await widget.workspace.confirmQuit()) return;
    widget.journal.freeze();
    await widget.settings.flush();
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => PlanchetteApp(
    workspace: widget.workspace,
    settings: widget.settings,
    navigatorKey: widget.navigatorKey,
    onQuit: _quit,
    appVersion: widget.appVersion,
  );

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.journal.dispose();
    widget.workspace.dispose();
    widget.settings.dispose();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'planchette_app.dart';
import 'services/android_documents.dart';
import 'services/app_settings.dart';
import 'services/document_dialogs.dart';
import 'services/document_workspace.dart';

/// The phone owns one workspace and uses the system document provider. Desktop
/// window channels must never run before this app's first frame.
Future<void> runAndroidApp() async {
  final documents = AndroidDocuments();
  final settings = SettingsController(
    store: LocalSettingsStore(File(await documents.settingsPath())),
  );
  await settings.load();
  final navigatorKey = GlobalKey<NavigatorState>();
  final workspace = DocumentWorkspace(
    store: documents,
    dialogs: AppDocumentDialogs(navigatorKey, android: documents),
    toolHistory: TextToolHistory.decode(settings.value.recentTextTools),
  );
  final recoveryPaths = await documents.recoveries();
  if (recoveryPaths.isEmpty) {
    workspace.newDocument();
  } else {
    await workspace.openAll(recoveryPaths);
  }
  runApp(_AndroidApp(workspace, settings, navigatorKey));
}

class _AndroidApp extends StatefulWidget {
  const _AndroidApp(this.workspace, this.settings, this.navigatorKey);

  final DocumentWorkspace workspace;
  final SettingsController settings;
  final GlobalKey<NavigatorState> navigatorKey;

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
      onInactive: () => unawaited(widget.settings.flush()),
    );
  }

  Future<void> _quit() async {
    if (!await widget.workspace.confirmQuit()) return;
    await widget.settings.flush();
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => PlanchetteApp(
    workspace: widget.workspace,
    settings: widget.settings,
    navigatorKey: widget.navigatorKey,
    onQuit: _quit,
  );

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.workspace.dispose();
    widget.settings.dispose();
    super.dispose();
  }
}

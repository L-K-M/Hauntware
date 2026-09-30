import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'planchette_app.dart';
import 'services/app_settings.dart';
import 'services/desktop_window.dart';
import 'services/document_dialogs.dart';
import 'services/document_store.dart';
import 'services/document_workspace.dart';
import 'services/open_documents.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loaded before the window exists: the stored theme is the one source for
  // both the app and the window's pre-paint color.
  final settings = SettingsController(
    store: LocalSettingsStore.defaultLocation(),
  );
  await settings.load();
  final navigatorKey = GlobalKey<NavigatorState>();
  final workspace = DocumentWorkspace(
    store: LocalDocumentStore(),
    dialogs: AppDocumentDialogs(navigatorKey),
    toolHistory: TextToolHistory.decode(settings.value.recentTextTools),
  );
  final desktop = DesktopWindow(
    confirmQuit: () async {
      if (!await workspace.confirmQuit()) return false;
      // A zoom or setting chosen just before quitting may still be on its
      // way to disk.
      await settings.flush();
      return true;
    },
    onQuitFailed: workspace.quitFailed,
    onFocus: () => unawaited(workspace.checkDisk()),
    windowBackgroundColor: windowBackdrop(
      effectiveBrightness(settings.value.themeMode),
    ),
  );
  runApp(
    PlanchetteApp(
      workspace: workspace,
      settings: settings,
      navigatorKey: navigatorKey,
      onQuit: desktop.requestQuit,
    ),
  );
  await desktop.initialize();
  workspace.addListener(() => desktop.setTitle(workspace.windowTitle));
  final intake = OpenDocuments(open: workspace.open);
  await intake.start(arguments, macOS: Platform.isMacOS);
  if (workspace.documents.isEmpty && workspace.error == null) {
    workspace.newDocument();
  }
}

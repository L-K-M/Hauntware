import 'dart:io';

import 'package:flutter/material.dart';

import 'planchette_app.dart';
import 'services/desktop_window.dart';
import 'services/document_dialogs.dart';
import 'services/document_store.dart';
import 'services/document_workspace.dart';
import 'services/open_documents.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  // One source for both the theme and the window's pre-paint color. A
  // persisted preference (A1) replaces this line and nothing else.
  const themeMode = ThemeMode.system;
  final navigatorKey = GlobalKey<NavigatorState>();
  final workspace = DocumentWorkspace(
    store: LocalDocumentStore(),
    dialogs: AppDocumentDialogs(navigatorKey),
  );
  final desktop = DesktopWindow(
    confirmQuit: workspace.confirmQuit,
    onQuitFailed: workspace.quitFailed,
    windowBackgroundColor: windowBackdrop(effectiveBrightness(themeMode)),
  );
  runApp(
    PlanchetteApp(
      workspace: workspace,
      navigatorKey: navigatorKey,
      onQuit: desktop.requestQuit,
      themeMode: themeMode,
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

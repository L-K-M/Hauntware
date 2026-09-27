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
  final navigatorKey = GlobalKey<NavigatorState>();
  final workspace = DocumentWorkspace(
    store: LocalDocumentStore(),
    dialogs: AppDocumentDialogs(navigatorKey),
  );
  final desktop = DesktopWindow(
    confirmQuit: workspace.confirmQuit,
    onQuitFailed: workspace.quitFailed,
  );
  runApp(
    PlanchetteApp(
      workspace: workspace,
      navigatorKey: navigatorKey,
      onQuit: desktop.requestQuit,
    ),
  );
  await desktop.initialize();
  workspace.addListener(() => desktop.setTitle(workspace.windowTitle));
  final intake = OpenDocuments(open: workspace.open);
  await intake.start(arguments, macOS: Platform.isMacOS);
  // Launching into the shell's empty state rather than a blank buffer. That
  // screen is the only place New and Open are offered, and an untitled
  // document with nothing in it answers neither.
}

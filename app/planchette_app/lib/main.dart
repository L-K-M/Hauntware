import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'planchette_app.dart';
import 'services/app_settings.dart';
import 'services/desktop_window.dart';
import 'services/document_dialogs.dart';
import 'services/document_store.dart';
import 'services/document_windows.dart';
import 'services/document_workspace.dart';
import 'services/open_documents.dart';
import 'services/semantics_view_routing.dart';
import 'services/window_host.dart';
import 'ui/document_windows_root.dart';

Future<void> main(List<String> arguments) async {
  PlanchetteBinding.ensureInitialized();
  // Loaded before the window exists: the stored theme is the one source for
  // both the app and the window's pre-paint color.
  final settings = SettingsController(
    store: LocalSettingsStore.defaultLocation(),
  );
  await settings.load();

  // The runner's window host and the app's windows: every window is a view
  // on the one engine, holding its own workspace over the shared settings
  // and text-tool history.
  final host = MethodChannelWindowHost();
  final toolHistory = TextToolHistory.decode(settings.value.recentTextTools);
  late final DocumentWindows windows;
  final desktop = DesktopWindow(
    confirmQuit: () async {
      // Quit reviews every window's documents, not only the main one's.
      if (!await windows.confirmAllClose()) return false;
      // A zoom or setting chosen just before quitting may still be on its
      // way to disk.
      await settings.flush();
      return true;
    },
    // Closures, not tear-offs: `windows` is assigned below them.
    onQuitFailed: (error) => windows.quitFailed(error),
    closeInstead: () => windows.closeMainWindowInstead(),
    onFocus: () => windows.onWindowActivated(mainWindowViewId),
    windowBackgroundColor: windowBackdrop(
      effectiveBrightness(settings.value.themeMode),
    ),
  );
  windows = DocumentWindows(
    host: host,
    workspaceFactory: (window) => DocumentWorkspace(
      store: LocalDocumentStore(),
      dialogs: AppDocumentDialogs(
        window.navigatorKey,
        pickers: WindowPickers(window),
      ),
      toolHistory: toolHistory,
    ),
    quitApplication: desktop.requestQuit,
    mainTitle: desktop.setTitle,
  );
  await windows.start();
  // The remembered frame goes on while the window is still off-screen: the
  // Linux and Windows runners show it on the first frame, and macOS keeps
  // it hidden until this show() runs — so the window must be placed before
  // the root mounts.
  await desktop.initialize();
  // runWidget, not runApp: runApp wraps the root in its own View for the
  // implicit view, and ViewCollection would then mount a second View for
  // view 0 — two render trees on one FlutterView is forbidden.
  runWidget(
    DocumentWindowsRoot(
      windows: windows,
      buildWindow: (window, menuSlot) => PlanchetteApp(
        workspace: window.workspace,
        settings: settings,
        window: window,
        menuSlot: menuSlot,
        onQuit: desktop.requestQuit,
      ),
    ),
  );

  // Finder/argv opens route through the windows: to whoever holds the file,
  // the active window, or a fresh one.
  final intake = OpenDocuments(open: windows.openDocuments);
  await intake.start(arguments, macOS: Platform.isMacOS);

  // The launch window gets the blank page; windows opened later start
  // empty and invite a document, like an empty tab set. A registry
  // disposed under start() leaves no window to seed.
  final open = windows.windows;
  if (open.isEmpty) return;
  final launch = open.firstWhere(
    (window) => window.isLaunchWindow,
    orElse: () => open.first,
  );
  if (launch.workspace.documents.isEmpty && launch.workspace.error == null) {
    launch.workspace.newDocument();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ghost_licenses/ghost_licenses.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import 'android_app.dart';
import 'planchette_app.dart';
import 'services/app_lock.dart';
import 'services/app_settings.dart';
import 'services/app_version.dart';
import 'services/desktop_window.dart';
import 'services/document_dialogs.dart';
import 'services/document_store.dart';
import 'services/document_windows.dart';
import 'services/document_workspace.dart';
import 'services/open_documents.dart';
import 'services/save_siblings.dart';
import 'services/semantics_view_routing.dart';
import 'services/session_journal.dart';
import 'services/window_host.dart';
import 'services/workspace_catalog.dart';
import 'services/workspace_remote_files.dart';
import 'ui/workspace_connection_prompts.dart';
import 'ui/document_windows_root.dart';

Future<void> main(List<String> arguments) async {
  PlanchetteBinding.ensureInitialized();
  // The licenses page lists the APK's Maven libraries too (Android).
  registerPlatformLicenses();
  final appVersion = await readAppVersion();
  if (Platform.isAndroid) {
    await runAndroidApp(appVersion: appVersion);
    return;
  }
  // Loaded before the window exists: the stored theme is the one source for
  // both the app and the window's pre-paint color.
  final settings = SettingsController(
    store: LocalSettingsStore.defaultLocation(),
  );
  await settings.load();
  // Before any window: the first frame of every window is already behind
  // the lock screen when the lock is on.
  final appLock = openAppLock(settings);

  // The hot-exit journal, in the app's private support folder; a second
  // running instance finds it locked and keeps nothing.
  final journal = SessionJournal(
    store: SessionJournalStore(
      Directory(
        paths.join((await getApplicationSupportDirectory()).path, 'session'),
      ),
    ),
    settings: settings,
    onError: (workspace, error) =>
        workspace.reportError(workspace.strings.journalWriteFailed(error)),
  );
  final kept = await journal.open();

  // The runner's window host and the app's windows: every window is a view
  // on the one engine, holding its own workspace over the shared settings
  // and text-tool history.
  final host = MethodChannelWindowHost();
  final toolHistory = TextToolHistory.decode(settings.value.recentTextTools);
  late final DocumentWindows windows;
  Future<WorkspaceRemoteFiles>? remoteFiles;
  // File-only launches never initialize the vault, sync transport or SSH pool.
  Future<WorkspaceRemoteFiles> openRemoteFiles() => remoteFiles ??= () async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(paths.join(support.path, 'workspaces'));
    return WorkspaceRemoteFiles(
      directory: directory,
      catalog: WorkspaceCatalog(
        directory: Directory(paths.join(directory.path, 'catalog')),
        // A locked app hands the catalog no credential.
        credentialReads: appLock.read,
      ),
      prompts: AppWorkspaceConnectionPrompts(
        () {
          final window = windows.activeWindow;
          final context = window?.navigatorKey.currentContext;
          if (window == null || context == null) return null;
          return (context: context, workspace: window.workspace);
        },
        pickKeyText: (workspace) =>
            (workspace.dialogs as AppDocumentDialogs).pickKeyText(),
      ),
      isDocumentOpen: (path) => windows.windows.any(
        (window) => window.workspace.tabForPath(path) != null,
      ),
      onError: (error, stack) {
        final workspace = windows.activeWindow?.workspace;
        if (workspace == null) {
          // No window can show the banner; the error log still gets it.
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
          return;
        }
        workspace.reportError(workspace.strings.remoteFileFailed(error));
      },
    );
  }();
  final desktop = DesktopWindow(
    confirmQuit: () async {
      // Quit reviews every window's documents, not only the main one's.
      if (!await windows.confirmAllClose()) return false;
      // Every window wrote its journal when it consented; the teardown
      // that follows must not change what the next launch restores.
      journal.freeze();
      // A zoom or setting chosen just before quitting may still be on its
      // way to disk.
      await settings.flush();
      return true;
    },
    // Closures, not tear-offs: `windows` is assigned below them.
    onQuitFailed: (error) {
      journal.thaw();
      windows.quitFailed(error);
    },
    closeInstead: () => windows.closeMainWindowInstead(),
    onFocus: () => windows.onWindowActivated(mainWindowViewId),
    windowBackgroundColor: windowBackdrop(
      effectiveBrightness(settings.value.themeMode),
    ),
  );
  windows = DocumentWindows(
    host: host,
    workspaceFactory: (window) {
      final dialogs = AppDocumentDialogs(
        window.navigatorKey,
        pickers: WindowPickers(window),
      );
      return DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: dialogs,
        toolHistory: toolHistory,
        saveSiblings: LocalSaveSiblings(),
        strings: () => dialogs.strings,
      );
    },
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
        pickFolder:
            (window.workspace.dialogs as AppDocumentDialogs).pickDirectory,
        remoteFiles: openRemoteFiles,
        appVersion: appVersion,
        appLock: appLock,
      ),
    ),
  );

  // Last session's windows come back before this launch's files open, so
  // those land in the restored active window.
  await journal.restoreInto(windows, kept);

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

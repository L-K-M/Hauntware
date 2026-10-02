// The app's document windows: which ones are open, which one the user is
// working in, and the open, close, and quit rules between them.
//
// Every window is a view on the app's one Flutter engine, rendered by
// `DocumentWindowsRoot` with its own shell, navigator, and
// DocumentWorkspace, over the services the windows share (settings, the
// text-tool history). The first window is the engine's implicit view,
// which cannot leave the engine, so closing it while other windows stay
// open hides it and drops its workspace; the next New Window shows it
// again with a fresh one.
import 'dart:async';

import 'package:flutter/material.dart' show ScaffoldMessengerState;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'document_workspace.dart';
import 'window_host.dart';

enum DocumentWindowKind {
  /// The engine's implicit view: window_manager's window. Closing it while
  /// other windows are open hides it rather than destroying its view.
  main,

  /// A window the runner created on the same engine.
  extra,
}

/// What a window's shell registers with its window, so activating the
/// window can put keyboard focus where it belongs.
abstract interface class DocumentWindowContent {
  /// Puts keyboard focus where a freshly activated window wants it (the
  /// active tab's editor). Called when the window becomes active and its
  /// focus scope remembers nothing.
  void claimDefaultFocus();
}

/// One open document window.
final class DocumentWindow {
  DocumentWindow._({
    required this.viewId,
    required this.kind,
    required this.serial,
    required this.owner,
  }) : navigatorKey = GlobalKey<NavigatorState>(
         debugLabel: 'window $serial navigator',
       ),
       scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>(
         debugLabel: 'window $serial messenger',
       ),
       focusScope = FocusScopeNode(debugLabel: 'window $serial');

  final int viewId;
  final DocumentWindowKind kind;

  /// Unique for the app's lifetime: the key of the window's widget subtree,
  /// so a main window shown again mounts afresh.
  final int serial;

  /// The window's own document set: its tabs, dirty state, and prompts.
  /// The registry fills it in from its factory at creation.
  late final DocumentWorkspace workspace;

  final GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;

  /// Everything the window shows sits under this scope, so activating the
  /// window can put focus back where it was in it.
  final FocusScopeNode focusScope;

  final DocumentWindows owner;
  DocumentWindowContent? _content;

  /// The title last pushed to the native window, for dedup and retry.
  String? _shownTitle;

  /// The title-sync subscription, kept so close and dispose can detach it.
  VoidCallback? _titleListener;

  bool get isMain => kind == DocumentWindowKind.main;

  /// Whether this is the window the app launched with: the startup file
  /// opens and the first blank document are its to reveal.
  bool get isLaunchWindow => serial == 0;

  /// Whether this is the window the user last worked in: the one whose
  /// menus the macOS menu bar shows and whose workspace dialogs open in.
  bool get isActive => identical(owner.activeWindow, this);

  /// Whether New Window can open one: the runner hosts extra windows.
  bool get canOpenWindows => owner.canOpenWindows;

  /// New Window.
  Future<void> openWindow() => owner.openWindow();

  /// Close Window, the same path as the window's close button: the last
  /// open window quits the app.
  Future<void> close() => owner.closeWindow(this);

  /// Activate: raises and focuses the native window.
  Future<void> activate() => owner._host.activate(viewId);

  void attachContent(DocumentWindowContent content) => _content = content;

  void detachContent(DocumentWindowContent content) {
    if (identical(_content, content)) _content = null;
  }

  void _restoreFocus() {
    if (focusScope.focusedChild != null) {
      focusScope.requestFocus();
      return;
    }
    _content?.claimDefaultFocus();
  }

  void _dispose() => focusScope.dispose();
}

/// The app's open document windows and the rules between them.
final class DocumentWindows extends ChangeNotifier
    implements WindowHostListener, PeerDocuments {
  DocumentWindows({
    required this._host,
    required this._workspaceFactory,
    required this.quitApplication,
    Future<void> Function()? afterFrame,
    this.mainTitle,
    this.onError,
  }) : _afterFrame = afterFrame ?? _endOfFrame;

  final WindowHost _host;

  /// Builds a window's workspace — its own documents on the app's shared
  /// services — once the window's keys exist for the dialogs to use.
  final DocumentWorkspace Function(DocumentWindow window) _workspaceFactory;

  /// Quits the whole app (the desktop window's requestQuit): reviews every
  /// window's documents and destroys the process's windows together.
  final Future<void> Function() quitApplication;

  /// Resolves once the frame that dropped a closing window's subtree has
  /// been built: the view must stop rendering before its native window
  /// goes.
  final Future<void> Function() _afterFrame;

  /// window_manager's title setter, for the main window only.
  final void Function(String title)? mainTitle;

  /// Where boundary failures with no window to blame go (the app's error
  /// reporter). Without one they land on the active window's banner.
  final void Function(Object, StackTrace)? onError;

  final _windows = <DocumentWindow>[];

  /// Most recently activated last.
  final _activation = <DocumentWindow>[];
  int _serials = 0;
  bool _hostAvailable = false;
  bool _started = false;
  bool _disposed = false;

  /// A quit review in flight, shared by Quit, the exit request, and the
  /// last window's close.
  Future<bool>? _quitReview;

  /// The review's bookkeeping: [_quitPending] while it asks, [_quitGranted]
  /// once every window consented and until the teardown lands or fails.
  bool _quitPending = false;
  bool _quitGranted = false;

  /// Serializes opening and closing, which both await the runner: two
  /// quick New Windows must not both reuse the hidden main window.
  Future<void> _tail = Future.value();

  late final GlobalKey<NavigatorState> navigatorKey =
      _ActiveWindowKey<NavigatorState>(
        () => activeWindow?.navigatorKey,
        'active window navigator',
      );

  late final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      _ActiveWindowKey<ScaffoldMessengerState>(
        () => activeWindow?.scaffoldMessengerKey,
        'active window messenger',
      );

  /// Bounded: frames stop while the app is hidden, and a close must not
  /// wait for one forever. Without the frame the view is only destroyed
  /// while its subtree is still mounted, which the engine tolerates.
  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 1), onTimeout: () {});

  /// The open windows, in the order they opened. The main window is absent
  /// while it is hidden.
  List<DocumentWindow> get windows => List.unmodifiable(_windows);

  /// The window the user last worked in, or the first open one.
  DocumentWindow? get activeWindow {
    for (final window in _activation.reversed) {
      if (_windows.contains(window)) return window;
    }
    return _windows.firstOrNull;
  }

  /// Whether New Window can open one: the runner hosts extra windows.
  bool get canOpenWindows => _hostAvailable;

  DocumentWindow? windowForView(int viewId) {
    for (final window in _windows) {
      if (window.viewId == viewId) return window;
    }
    return null;
  }

  /// Records the main window — already on screen, shown by window_manager —
  /// and asks whether the runner can host more.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _host.listener = this;
    try {
      _hostAvailable = await _host.isAvailable();
    } on Object catch (error, stack) {
      _report(error, stack);
      _hostAvailable = false;
    }
    if (_disposed) return;
    final main = _newWindow(mainWindowViewId, DocumentWindowKind.main);
    _windows.add(main);
    _activation.add(main);
    notifyListeners();
  }

  /// New Window: shows the hidden main window again, fresh, or asks the
  /// runner for another one. The new window becomes the active one.
  Future<void> openWindow() => _serialized(() async {
    await _openWindow();
  });

  /// Creates or reuses a window and answers it; null when the runner
  /// cannot or the app is going away.
  Future<DocumentWindow?> _openWindow() async {
    if (!_hostAvailable || _disposed || _quitting) return null;

    if (windowForView(mainWindowViewId) == null) {
      final main = _newWindow(mainWindowViewId, DocumentWindowKind.main);
      _windows.add(main);
      _activate(main);
      notifyListeners();
      // Its first frame before it shows, so it never shows the workspace
      // it had when it was closed.
      await _afterFrame();
      await _host.activate(mainWindowViewId);
      return main;
    }

    final int viewId;
    try {
      viewId = await _host.create();
    } on Object catch (error, stack) {
      _report(error, stack);
      _reportError('Could not open a window: $error');
      return null;
    }
    if (_disposed || _quitting) {
      // The view arrived into an app that is leaving: it must go before it
      // can open.
      await _host.destroy(viewId);
      return null;
    }
    final window = _newWindow(viewId, DocumentWindowKind.extra);
    _windows.add(window);
    // The runner already made it key; its report may have arrived before
    // this reply, when there was no window to credit it to.
    _activate(window);
    notifyListeners();
    return window;
  }

  /// A native file-open request — Finder, `open -a`, a second invocation's
  /// argv, the window's own Open dialog settling elsewhere — lands in the
  /// active window, in a fresh one when none is open, or focuses the window
  /// already holding the file.
  Future<void> openDocument(String path) => _serialized(() async {
    // Wait out a quit review already under way: a cancelled quit still
    // opens the file; an accepted one exits before this can run.
    await _quitReview;
    if (_disposed || _quitPending || _quitGranted) return;
    for (final window in _windows) {
      final tab = window.workspace.tabForPath(path);
      if (tab != null) {
        window.workspace.revealTab(tab);
        await _host.activate(window.viewId);
        return;
      }
    }
    final target = activeWindow ?? await _openWindow();
    if (target == null) return;
    // The raise is the open's, not the runner's: whoever holds the file —
    // or takes it — comes forward, never the main window on principle
    // (it may be hidden while other windows are open).
    await _host.activate(target.viewId);
    await target.workspace.open(path);
  });

  /// The app-wide quit review: every open window consents to its own
  /// documents closing, each in turn and raised while it asks. A declined
  /// answer cancels the quit for every window — none closes — and the lock
  /// an earlier consent left behind is released. The review in flight is
  /// shared, so Quit, the OS's exit request, and the last window's close
  /// walk it together.
  Future<bool> confirmAllClose() {
    if (_quitGranted) return Future.value(true);
    return _quitReview ??= _reviewAllClose().whenComplete(() {
      _quitReview = null;
    });
  }

  Future<bool> _reviewAllClose() async {
    if (_disposed) return false;
    _quitPending = true;
    var granted = false;
    try {
      for (final window in List.of(_windows)) {
        if (!_windows.contains(window)) continue;
        // The window its prompt belongs to comes forward to ask it.
        await _host.activate(window.viewId);
        if (!await window.workspace.confirmQuit()) return false;
      }
      granted = true;
      _quitGranted = true;
      return true;
    } finally {
      _quitPending = false;
      if (!granted) {
        for (final window in _windows) {
          window.workspace.releaseQuit();
        }
      }
    }
  }

  /// A native teardown that failed after the review's consent: the app is
  /// not going anywhere, so every lock the acceptance left behind is
  /// released and the failure is reported.
  void quitFailed(Object error) {
    _quitGranted = false;
    _quitPending = false;
    for (final window in _windows) {
      window.workspace.releaseQuit();
    }
    _reportError('Could not close Planchette: $error');
  }

  /// Close Window and a window's close button: closes [window] once its
  /// own dirty documents consent, or quits the app when it is the last one
  /// open (the quit path reviews it there, as for Quit).
  Future<void> closeWindow(DocumentWindow window) =>
      _serialized(() => _closeWindow(window));

  Future<void> _closeWindow(DocumentWindow window) async {
    if (!_windows.contains(window) || _disposed || _quitting) return;
    if (_windows.length == 1) {
      await quitApplication();
      return;
    }

    if (!await window.workspace.confirmQuit()) return;
    if (_disposed || _quitting || !_windows.contains(window)) return;

    _windows.remove(window);
    _activation.remove(window);
    _detachTitleSync(window);
    notifyListeners();
    // The subtree goes in this frame; the view after it.
    await _afterFrame();
    if (_disposed) {
      // The app is going: the runner takes its windows with it.
      window._dispose();
      return;
    }
    try {
      if (window.isMain) {
        await _host.hide(mainWindowViewId);
      } else {
        await _host.destroy(window.viewId);
      }
    } on Object catch (error, stack) {
      // The native window is still up but its widgets were gone for a
      // frame: put the record back so it renders again, release the lock
      // the review left, and keep the close retryable.
      window.workspace.releaseQuit();
      _windows.add(window);
      _watchTitleSync(window);
      _activate(window);
      notifyListeners();
      window.workspace.reportError('Could not close the window: $error');
      _report(error, stack);
      return;
    }
    window.workspace.dispose();
    window._dispose();
    final next = activeWindow;
    if (next != null && !_disposed) await _host.activate(next.viewId);
  }

  /// The main window's close button, as window_manager reports it. True
  /// when it was only this window that closed (hidden while other windows
  /// stay open); false when the app should quit, which the caller's quit
  /// path does. Decided in turn with the other opens and closes: one still
  /// under way can change how many windows are open.
  Future<bool> closeMainWindowInstead() async {
    var closedInstead = false;
    await _serialized(() async {
      final main = windowForView(mainWindowViewId);
      if (main == null || _windows.length == 1 || _disposed) return;
      closedInstead = true;
      await _closeWindow(main);
    });
    return closedInstead;
  }

  @override
  void onWindowActivated(int viewId) {
    final window = windowForView(viewId);
    if (window == null || _disposed) return;
    final changed = !window.isActive;
    _activate(window);
    if (changed) notifyListeners();
    window._restoreFocus();
    // Files other programs changed while this window sat behind are
    // noticed as it comes forward.
    unawaited(window.workspace.checkDisk());
  }

  @override
  void onWindowCloseRequested(int viewId) {
    final window = windowForView(viewId);
    if (window == null) return;
    unawaited(closeWindow(window));
  }

  /// A window's own native file dialogs, owned by its view. file_selector
  /// parents every dialog to the plugin registry's view — the main window —
  /// which may be hidden while other windows are open, so windows that can
  /// be one of several go through the runner's host instead.
  Future<List<String>> pickOpenFiles(DocumentWindow window) =>
      _host.pickOpenFiles(window.viewId);

  Future<String?> pickSavePath(
    DocumentWindow window, {
    required String suggestedName,
    String? initialDirectory,
  }) => _host.pickSavePath(
    window.viewId,
    suggestedName: suggestedName,
    initialDirectory: initialDirectory,
  );

  // -- PeerDocuments: the app-wide open-file dedup -----------------------

  @override
  ({DocumentWorkspace workspace, DocumentTab tab})? tabHolding(
    String path, {
    required DocumentWorkspace except,
  }) {
    for (final window in _windows) {
      if (identical(window.workspace, except)) continue;
      final tab = window.workspace.tabForPath(path);
      if (tab != null) return (workspace: window.workspace, tab: tab);
    }
    return null;
  }

  @override
  void focusTab(DocumentWorkspace workspace, DocumentTab tab) {
    workspace.revealTab(tab);
    for (final window in _windows) {
      if (identical(window.workspace, workspace)) {
        unawaited(_host.activate(window.viewId));
        return;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _host.listener = null;
    for (final window in _windows) {
      _detachTitleSync(window);
      window.workspace.dispose();
      window._dispose();
    }
    _windows.clear();
    _activation.clear();
    super.dispose();
  }

  DocumentWindow _newWindow(int viewId, DocumentWindowKind kind) {
    final window = DocumentWindow._(
      viewId: viewId,
      kind: kind,
      serial: _serials++,
      owner: this,
    );
    window.workspace = _workspaceFactory(window)..peers = this;
    _watchTitleSync(window);
    return window;
  }

  void _watchTitleSync(DocumentWindow window) {
    void push() => _syncTitle(window);
    window._titleListener = push;
    window.workspace.addListener(push);
    push();
  }

  void _detachTitleSync(DocumentWindow window) {
    final listener = window._titleListener;
    if (listener == null) return;
    window.workspace.removeListener(listener);
    window._titleListener = null;
  }

  /// window_manager serves only the main window; every other window's
  /// title goes through the host. A title that never arrived is forgotten
  /// so the next change sends it again, as DesktopWindow's own sync does.
  void _syncTitle(DocumentWindow window) {
    final title = window.workspace.windowTitle;
    if (window._shownTitle == title) return;
    window._shownTitle = title;
    if (window.isMain) {
      mainTitle?.call(title);
      return;
    }
    unawaited(
      _host.setTitle(window.viewId, title).catchError((Object error) {
        if (window._shownTitle == title) window._shownTitle = null;
      }),
    );
    // The title is part of the window list's rows; refresh the menus that
    // name this window.
    notifyListeners();
  }

  void _activate(DocumentWindow window) {
    _activation
      ..remove(window)
      ..add(window);
  }

  bool get _quitting => _quitPending || _quitGranted;

  /// The failure on the active window's banner, or nowhere visible when no
  /// window can carry it (then the log still has it).
  void _reportError(String message) {
    final window = activeWindow;
    if (window == null) {
      FlutterError.reportError(FlutterErrorDetails(exception: message));
      return;
    }
    window.workspace.reportError(message);
  }

  void _report(Object error, StackTrace stack) {
    final sink = onError;
    if (sink != null) {
      sink(error, stack);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    );
  }

  Future<void> _serialized(Future<void> Function() operation) {
    final run = _tail.then((_) => operation());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run.catchError((Object error, StackTrace stack) {
      _report(error, stack);
    });
  }
}

/// One window's native file dialogs. `AppDocumentDialogs` holds this for a
/// window that can be one of several; when the runner hosts no extra
/// windows the main window is always visible and the dialogs keep using
/// file_selector's.
final class WindowPickers {
  const WindowPickers(this._window);

  final DocumentWindow _window;

  /// Whether the runner can parent a dialog to this window's view.
  bool get available => _window.owner.canOpenWindows;

  Future<List<String>> pickOpenFiles() => _window.owner.pickOpenFiles(_window);

  Future<String?> pickSavePath({
    required String suggestedName,
    String? initialDirectory,
  }) => _window.owner.pickSavePath(
    _window,
    suggestedName: suggestedName,
    initialDirectory: initialDirectory,
  );
}

/// A key that is never mounted: it answers for the active window's key.
///
/// Callers that take one navigator key — dialogs and prompts raised above
/// whatever window is in front — read `currentContext` when they show
/// something. With several windows the right navigator is the one in the
/// window the user is working in, and it changes, so they get this instead
/// of any one window's key.
final class _ActiveWindowKey<T extends State<StatefulWidget>>
    extends LabeledGlobalKey<T> {
  _ActiveWindowKey(this._resolve, String label) : super(label);

  final GlobalKey<T>? Function() _resolve;

  @override
  BuildContext? get currentContext => _resolve()?.currentContext;

  @override
  Widget? get currentWidget => _resolve()?.currentWidget;

  @override
  T? get currentState => _resolve()?.currentState;
}

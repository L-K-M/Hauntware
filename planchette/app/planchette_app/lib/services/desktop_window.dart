import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:window_manager/window_manager.dart';

import 'window_state.dart';

/// Keeps both native close routes behind the workspace's shared dirty guard,
/// and the primary window's remembered frame behind the shared lifecycle.
///
/// Only the primary window runs through this: extra document windows are
/// native, driven by the runner's window host, and keep their own placement.
final class DesktopWindow with WindowListener {
  DesktopWindow({
    required this.confirmQuit,
    required this.onQuitFailed,
    this.onFocus,
    this.closeInstead,
    this.windowBackgroundColor,
    GhostWindowPersistence? persistence,
    GhostWindowAdapter? window,
    GhostDisplayAdapter? displays,
    GhostDesktopPlatform? platform,
    void Function() Function(Duration, Future<void> Function())?
    scheduleDebounce,
    Future<void> Function(String title)? setWindowTitle,
  }) : _window = window ?? WindowManagerGhostWindowAdapter(),
       _setWindowTitle = setWindowTitle ?? windowManager.setTitle {
    _lifecycle = GhostWindowLifecycle(
      persistence: persistence ?? WindowStateStore.defaultLocation(),
      closePolicy: GhostClosePolicy.intercept,
      missingMonitor: MissingMonitorPolicy.rejectAndKeep,
      // Physical pixels on Windows: the same space Séance's file established,
      // stable across mixed-DPI relaunches.
      coordinates: GhostCoordinateSpace.physicalOnWindows,
      // Linux and Windows runners show the window themselves on the first
      // frame — initialize() runs before runWidget so the restored frame is
      // in place by then. macOS exempts itself: its window is hidden at
      // launch and only the lifecycle can show it.
      showTrigger: GhostShowTrigger.runner,
      window: _window,
      displays: displays,
      platform: platform,
      scheduleDebounce: scheduleDebounce,
      windowDefaults: _sharedOptions(windowOptions),
      // The close button can mean "just this window" while other windows
      // stay up; a programmatic quit (menu, exit request) must never take
      // that branch.
      closeInstead: () async {
        if (_quitRequested) return false;
        return await closeInstead?.call() ?? false;
      },
      confirmClose: confirmQuit,
      onError: (error, _) => onQuitFailed(error),
    );
    // Never completes when the window failed to come up: no title then.
    unawaited(_lifecycle.windowReady.then((_) => _onWindowReady()));
  }

  final Future<bool> Function() confirmQuit;
  final void Function(Object error) onQuitFailed;

  /// The main window's close button, when other windows can stay open:
  /// answers true when this window closed alone (hidden — the engine's
  /// implicit view cannot leave), false when the app should quit. Null in
  /// the one-window app, where a close always means quit.
  final Future<bool> Function()? closeInstead;

  /// Called when the window becomes active again, so files that other
  /// programs changed in the meantime are noticed.
  final VoidCallback? onFocus;

  /// The color the native window paints before the first Flutter frame. Left
  /// unset the platform shows its own default, which reads as a white flash on
  /// a dark desktop.
  final Color? windowBackgroundColor;

  final GhostWindowAdapter _window;
  late final GhostWindowLifecycle _lifecycle;
  final Future<void> Function(String title) _setWindowTitle;
  AppLifecycleListener? _appLifecycle;
  bool _quitRequested = false;
  bool _windowReady = false;
  String? _title;

  /// Public rather than inline in [initialize] so the geometry and the
  /// pre-paint backdrop can be asserted without the platform channel.
  WindowOptions get windowOptions => WindowOptions(
    // The Linux and Windows runners open the window at this size, centered,
    // so it has its final geometry before this applies. Change them together.
    size: const Size(1080, 760),
    minimumSize: const Size(640, 400),
    center: true,
    title: 'Planchette',
    backgroundColor: windowBackgroundColor,
  );

  static GhostWindowOptions _sharedOptions(WindowOptions options) =>
      GhostWindowOptions(
        // windowOptions always sets one; the plugin's field is nullable only
        // because callers may leave the platform default.
        size: options.size!,
        minimumSize: options.minimumSize,
        title: options.title,
        backgroundColor: options.backgroundColor,
      );

  Future<void> initialize() async {
    // Focus stays app-side: the disk check on activation is Planchette's,
    // not the lifecycle's.
    windowManager.addListener(this);
    _appLifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (!await confirmQuit()) return AppExitResponse.cancel;
        // The OS tears the window down after an accepted exit without a
        // close event, so the last geometry save runs here instead.
        await _lifecycle.saveBounds();
        return AppExitResponse.exit;
      },
    );
    try {
      await _lifecycle.prepare();
    } catch (_) {
      // Already reported through the lifecycle's onError. Swallow so the
      // root still mounts — a failed restore must not become a blank,
      // dead window now that this runs before runWidget.
    } finally {
      // Always reached: on macOS the window is hidden at launch and show()
      // is the only exit from that — even after a failed prepare. A show
      // whose restore still fails rethrows after reporting through the
      // lifecycle's onError; swallow here as well so runWidget always
      // mounts rather than dying on a blank window.
      try {
        await _lifecycle.show();
      } catch (_) {
        // Restore failures were already reported through the lifecycle's
        // onError; swallowed so runWidget still mounts. A show() path that
        // throws without reporting is a lifecycle bug.
      }
    }
  }

  /// A programmatic quit — the menu's Quit, the runner's exit request
  /// path. Unlike the window's own close button it is never intercepted by
  /// [closeInstead]; the guard still applies.
  Future<void> requestQuit() async {
    if (_quitRequested) return;
    _quitRequested = true;
    try {
      final closed = await _lifecycle.close();
      if (!closed) _quitRequested = false;
    } catch (error) {
      _quitRequested = false;
      onQuitFailed(error);
    }
  }

  @override
  void onWindowFocus() => onFocus?.call();

  /// Each call is a platform channel message; skip the ones that would not
  /// change what the window shows.
  ///
  /// The document windows name the main window before [initialize] runs.
  /// window_manager has no window until the lifecycle's windowReady (its
  /// macOS plugin crashes on an earlier title), and the pre-show options
  /// set the default title then, so only the latest title waits for it.
  void setTitle(String title) {
    if (title == _title) return;
    _title = title;
    if (!_windowReady) return;
    _sendTitle(title);
  }

  void _onWindowReady() {
    _windowReady = true;
    final title = _title;
    if (title != null) _sendTitle(title);
  }

  void _sendTitle(String title) {
    unawaited(
      _setWindowTitle(title).catchError((Object _) {
        // Forget a title that never arrived so the next request retries it.
        if (title == _title) _title = null;
      }),
    );
  }

  void dispose() {
    _lifecycle.dispose();
    windowManager.removeListener(this);
    _appLifecycle?.dispose();
  }
}

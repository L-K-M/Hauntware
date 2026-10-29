import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show writeFileAtomically;

/// The main window's remembered frame and presentation flags, beside
/// `settings.json` in the app's support directory (03 §4.10).
const String windowStateFileName = 'window_state.json';

/// How long a move or resize settles before the frame is written: one
/// write per drag, not one per pixel (Séance's delay).
const Duration _geometrySaveDelay = Duration(milliseconds: 500);

/// Loads and saves the window state as `window_state.json`, in the shape
/// Séance's file established and Planchette's shares
/// ([GhostWindowSnapshot.toJson]: `x`, `y`, `width`, `height`,
/// `isMaximized`, `isFullScreen`).
///
/// Kept out of `settings.json` on purpose, as Séance and Planchette keep
/// theirs: a dragged resize saves on a debounce, and those writes have no
/// business rewriting the file that carries the device's sync id each
/// time. The file is device-local and never synced; on Windows its bounds
/// are physical pixels ([GhostCoordinateSpace.physicalOnWindows]).
final class WindowStateStore implements GhostWindowPersistence {
  /// `writer` replaces the file's contents; a seam for tests.
  WindowStateStore(this._file, {this._writer = writeFileAtomically});

  final File _file;
  final Future<void> Function(File target, List<int> bytes) _writer;
  Future<void> _saveTail = Future<void>.value();

  /// The stored state, or null when there is none. This runs before the
  /// window is shown, so a file that is missing, unreadable or not a
  /// snapshot reads as nothing saved rather than keeping the window from
  /// opening; the next save overwrites it. Window geometry is cheap to
  /// lose, so there is no corrupt copy as `settings.json` keeps.
  @override
  Future<GhostWindowSnapshot?> load() async {
    try {
      if (!await _file.exists()) return null;
      return GhostWindowSnapshot.fromJson(
        jsonDecode(await _file.readAsString()),
      );
    } on Object {
      return null;
    }
  }

  /// Replaces the file atomically through the writer `settings.json` uses,
  /// one save at a time in the order they were asked for.
  @override
  Future<void> save(GhostWindowSnapshot snapshot) {
    final bytes = utf8.encode(jsonEncode(snapshot.toJson()));
    final saved = _saveTail.then((_) => _writer(_file, bytes));
    _saveTail = saved.then<void>((_) {}, onError: (Object _) {});
    return saved;
  }
}

/// The desktop platform the window lifecycle runs on, or null where there
/// is no window to remember (phones, tablets, the web).
GhostDesktopPlatform? ghostDesktopPlatformFor(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.linux => GhostDesktopPlatform.linux,
    TargetPlatform.macOS => GhostDesktopPlatform.macos,
    TargetPlatform.windows => GhostDesktopPlatform.windows,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => null,
  };
}

/// The main window's lifecycle on ghost_desktop's shared
/// [GhostWindowLifecycle], with Klabautermann's choices on its knobs:
///
/// - Séance's contract for when it runs: restored in `main` before
///   `runApp`, so the runners on Linux and Windows show the window on the
///   first frame ([GhostShowTrigger.runner]) and the macOS runner keeps it
///   hidden until [GhostWindowLifecycle.show] has placed it.
/// - The native close is intercepted ([GhostClosePolicy.intercept]) so
///   [confirmClose] can veto it: the app's gate asks before quitting
///   while detached operations still run (`confirmQuitWhileRunning` in
///   lib/ui/actions/quit_guard.dart), and answers true otherwise.
/// - A frame that no longer fits the connected displays is clamped onto
///   the one it overlapped most, or centred on the primary one
///   ([MissingMonitorPolicy.clampToNearest], Poltergeist's rule), so the
///   window always opens fully on screen, also when only part of it would
///   have been off screen.
/// - Physical pixels on Windows ([GhostCoordinateSpace.physicalOnWindows],
///   Séance's reason): window_manager converts with the current monitor's
///   ratio, so no logical space is stable across a mixed-DPI relaunch.
///
/// [window], [displays], [platform] and [scheduleDebounce] are test seams;
/// production passes none of them.
GhostWindowLifecycle mainWindowLifecycle({
  required GhostWindowPersistence persistence,
  GhostWindowAdapter? window,
  GhostDisplayAdapter? displays,
  GhostDesktopPlatform? platform,
  Future<bool> Function()? confirmClose,
  void Function() Function(Duration, Future<void> Function())? scheduleDebounce,
}) {
  return GhostWindowLifecycle(
    persistence: persistence,
    closePolicy: GhostClosePolicy.intercept,
    confirmClose: confirmClose,
    missingMonitor: MissingMonitorPolicy.clampToNearest,
    coordinates: GhostCoordinateSpace.physicalOnWindows,
    showTrigger: GhostShowTrigger.runner,
    window: window,
    displays: displays,
    platform: platform,
    geometrySaveDelay: _geometrySaveDelay,
    scheduleDebounce: scheduleDebounce,
    onError: (error, _) => debugPrint('Window state: $error'),
  );
}

/// Puts the main window back where it was closed (size, monitor, maximized
/// or full screen) and keeps tracking it. Returns the lifecycle, or null on
/// a [platform] with no window to remember. The lifecycle stays alive while
/// the app runs because the window adapter holds it as its listener.
///
/// Call it once per launch in the app's isolate, before `runApp`, and
/// never in the settings window's engine or in a second instance, which
/// uses [showMainWindowUnrestored]. Never throws: a failure is logged and
/// the window keeps the runner's placement. On macOS it is also what makes
/// the hidden-at-launch window visible (`MainFlutterWindow.swift`'s `order`
/// override), and the lifecycle shows the window even when restoring
/// failed.
Future<GhostWindowLifecycle?> restoreMainWindow({
  required File stateFile,
  required TargetPlatform platform,
  GhostWindowAdapter? window,
  GhostDisplayAdapter? displays,
  Future<bool> Function()? confirmClose,
}) async {
  final desktop = ghostDesktopPlatformFor(platform);
  if (desktop == null) return null;

  final lifecycle = mainWindowLifecycle(
    persistence: WindowStateStore(stateFile),
    window: window,
    displays: displays,
    platform: desktop,
    confirmClose: confirmClose,
  );
  try {
    await lifecycle.prepare();
  } on Object {
    // Reported through onError. show() below still runs: after a failed
    // prepare it only rescues the hidden macOS window.
  }
  try {
    await lifecycle.show();
  } on Object {
    // Reported through onError; the lifecycle already tried to show the
    // window on macOS.
  }
  return lifecycle;
}

/// Shows the main window where the runner placed it, without
/// `window_state.json`: for a second desktop instance (03 §4.10), which
/// must neither read nor overwrite the frame the running instance owns.
/// Only macOS needs it, because its runner keeps the window hidden until
/// Dart shows it (`MainFlutterWindow.swift`'s `order` override); the Linux
/// and Windows runners show theirs on the first frame. Never throws: a
/// failure is logged. [window] is a test seam.
Future<void> showMainWindowUnrestored({
  required TargetPlatform platform,
  GhostWindowAdapter? window,
}) async {
  if (platform != TargetPlatform.macOS) return;

  window ??= WindowManagerGhostWindowAdapter();
  try {
    // window_manager's macOS calls reach the window only once the plugin
    // has been initialized with it.
    await window.ensureInitialized();
    await window.show();
    await window.focus();
  } on Object catch (error) {
    debugPrint('Window state: $error');
  }
}

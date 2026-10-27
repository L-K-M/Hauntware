import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'atomic_file.dart';

/// Loads and saves the window state as `window_state.json`. Kept out of
/// settings.json on purpose: geometry changes with every move/resize, and the
/// settings file — which carries the device's sync identity — should not be
/// rewritten that often (and it isn't loaded until after the first frame,
/// which is too late to place the window without a flash).
///
/// This is the store as the shared lifecycle sees it: Séance's file keeps its
/// schema (and its physical-pixel units on Windows — see the coordinate space
/// on the lifecycle below), the package never learns either.
final class WindowStateStore implements GhostWindowPersistence {
  final File file;
  Future<void> _saveTail = Future<void>.value();

  WindowStateStore(this.file);

  @override
  Future<GhostWindowSnapshot?> load() async {
    try {
      if (!await file.exists()) return null;
      return GhostWindowSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(GhostWindowSnapshot snapshot) {
    final contents = jsonEncode(snapshot.toJson());
    final result = Completer<void>();
    _saveTail = _saveTail.then((_) async {
      try {
        await writeStringAtomically(file, contents);
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// Restores the persisted window state at launch and keeps it current while
/// the app runs. Desktop only — a no-op on mobile.
///
/// The behavior lives in ghost_desktop's [GhostWindowLifecycle]; this stays
/// the entry point because Séance's contract is distinctive: restoration runs
/// in `main()` before `runApp` while the runner's hidden-at-launch window
/// waits, the saved file stores physical pixels on Windows, and the native
/// close is observed — never intercepted — so the window always closes
/// itself, except on macOS, where it is intercepted to hide the window
/// instead ([mainWindowShown]).
///
/// Wiring contract (macOS): `MainFlutterWindow` hides the window at launch
/// (`hiddenWindowAtLaunch()` in its `order` override) so the saved frame can
/// be applied off-screen. The lifecycle's `show` is what makes the window
/// visible again — it reaches `show()` on macOS even when restoring fails —
/// so this must run before `runApp`.
final class WindowStateService {
  WindowStateService._();

  /// Keeps the listener alive for the process lifetime; also the reentry
  /// guard, since the window can only be restored once per launch.
  static GhostWindowLifecycle? _instance;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  /// macOS: whether the main window is on screen. Its close button hides it
  /// rather than closing it: Séance keeps running in the Dock with its
  /// sessions, as Mail and Messages keep theirs, and the Dock icon or
  /// Window ▸ Séance brings it back ([showMainWindow]).
  static final ValueNotifier<bool> mainWindowShown = ValueNotifier(true);

  /// Shows the main window again and makes it key.
  static Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
    mainWindowShown.value = true;
  }

  /// The close button on macOS: hide, and tell the lifecycle the close is
  /// handled, so nothing quits.
  static Future<bool> _hideInsteadOfClosing() async {
    await windowManager.hide();
    mainWindowShown.value = false;
    return true;
  }

  static Future<void> restoreAndTrack() async {
    if (!_isDesktop || _instance != null) return;
    try {
      // First: the catch's macOS fallback shows the window through this
      // plugin, so it must be usable even when the earliest awaits fail.
      await windowManager.ensureInitialized();
      final dir = await getApplicationSupportDirectory();
      final lifecycle = GhostWindowLifecycle(
        persistence: WindowStateStore(File('${dir.path}/window_state.json')),
        // macOS keeps the app, and the window's sessions, when the window
        // closes; elsewhere the close is observed and the app ends with it.
        closePolicy: Platform.isMacOS
            ? GhostClosePolicy.intercept
            : GhostClosePolicy.observe,
        closeInstead: Platform.isMacOS ? _hideInsteadOfClosing : null,
        missingMonitor: MissingMonitorPolicy.rejectAndKeep,
        coordinates: GhostCoordinateSpace.physicalOnWindows,
        // The runners show the window on the first Flutter frame; asking for
        // it earlier would show it unpainted.
        showTrigger: GhostShowTrigger.runner,
        geometrySaveDelay: const Duration(milliseconds: 500),
        onError: (error, _) => debugPrint('Window state save failed: $error'),
      );
      _instance = lifecycle;
      await lifecycle.prepare();
      await lifecycle.show();
    } catch (error) {
      debugPrint('Window state restore failed: $error');
      if (Platform.isMacOS) {
        // The macOS runner keeps the window hidden until we show it; a restore
        // failure must not leave the app invisible.
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'atomic_file.dart';

/// The window state as `window_state.json`, written through the atomic
/// writer the other stores use. Its schema and its physical-pixel units on
/// Windows (see the coordinate space on the lifecycle below) are the ones
/// Séance's file established; ghost_desktop's [GhostWindowStateFile]
/// carries both unchanged. Kept out of settings.json also because that file
/// isn't loaded until after the first frame, too late to place the window
/// without a flash.
GhostWindowStateFile windowStateFile(File file) => GhostWindowStateFile(
  file,
  write: (target, json) => writeStringAtomically(target, jsonEncode(json)),
);

/// Restores the persisted window state at launch and keeps it current while
/// the app runs. Desktop only — a no-op on mobile.
///
/// The behavior lives in ghost_desktop's [GhostWindowLifecycle]; this stays
/// the entry point because Séance's contract is distinctive: restoration runs
/// in `main()` before `runApp` while the runner's hidden-at-launch window
/// waits, the saved file stores physical pixels on Windows, and the native
/// close is intercepted so dirty buffers and active sessions can veto it.
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

  static Future<void> restoreAndTrack({
    required Future<bool> Function() confirmClose,
    VoidCallback? onCloseFailed,
  }) async {
    if (!_isDesktop || _instance != null) return;
    try {
      // First: the catch's macOS fallback shows the window through this
      // plugin, so it must be usable even when the earliest awaits fail.
      await windowManager.ensureInitialized();
      final dir = await getApplicationSupportDirectory();
      final lifecycle = GhostWindowLifecycle(
        persistence: windowStateFile(File('${dir.path}/window_state.json')),
        closePolicy: GhostClosePolicy.intercept,
        missingMonitor: MissingMonitorPolicy.rejectAndKeep,
        coordinates: GhostCoordinateSpace.physicalOnWindows,
        // The runners show the window on the first Flutter frame; asking for
        // it earlier would show it unpainted.
        showTrigger: GhostShowTrigger.runner,
        geometrySaveDelay: const Duration(milliseconds: 500),
        confirmClose: confirmClose,
        onError: (error, _) => debugPrint('Window lifecycle failed: $error'),
        onCloseFailed: (_, _) => onCloseFailed?.call(),
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

  /// Persists the final frame for an accepted OS exit such as Cmd-Q, which
  /// may not produce the native close event used by the intercepted path.
  static Future<void> saveBounds() =>
      _instance?.saveBounds() ?? Future<void>.value();
}

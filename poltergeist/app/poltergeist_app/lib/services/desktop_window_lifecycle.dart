import 'dart:async';
import 'dart:ui';

import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:macos_window_utils/macos_window_utils.dart';

import 'app_preferences.dart';

const _initialWindowSize = Size(1180, 760);
const _minimumContentSize = Size(720, 480);
const _defaultGeometrySaveDelay = Duration(milliseconds: 250);

abstract interface class MacTitlebarAdapter {
  Future<void> initialize();
}

/// The persisted window bounds, as the shared lifecycle sees them: the
/// `window.*` keys in the settings store keep their shape (logical pixels,
/// no presentation flags — an install that never recorded flags must not
/// start emitting them).
final class _WindowBoundsPersistence implements GhostWindowPersistence {
  _WindowBoundsPersistence(this._preferences);

  final AppPreferences _preferences;

  @override
  Future<GhostWindowSnapshot?> load() async {
    final bounds = await _preferences.loadWindowBounds();
    if (bounds == null) return null;
    return GhostWindowSnapshot(bounds: bounds);
  }

  @override
  Future<void> save(GhostWindowSnapshot snapshot) {
    final bounds = snapshot.bounds;
    if (bounds == null) return Future.value();
    return _preferences.saveWindowBounds(bounds);
  }
}

/// Restores the main window's remembered frame and keeps it current while
/// the app runs — the Poltergeist face of ghost_desktop's
/// [GhostWindowLifecycle], which now owns the serialized window operations,
/// the debounced geometry tracking, and the guarded close path.
///
/// Poltergeist's choices on the shared knobs: bounds-only persistence in
/// logical pixels ([_WindowBoundsPersistence]), a missing monitor clamps the
/// frame onto the nearest work area rather than waiting for it to return,
/// the native close is intercepted so the quit guard and the session flush
/// get their say, and [show] runs after `runApp` so the service shows and
/// focuses the window itself.
final class DesktopWindowLifecycle extends GhostWindowLifecycle {
  DesktopWindowLifecycle(
    AppPreferences preferences, {
    super.window,
    super.displays,
    MacTitlebarAdapter? titlebar,
    super.platform,
    super.geometrySaveDelay = _defaultGeometrySaveDelay,
    super.scheduleDebounce,
    super.onCloseFlush,
    super.confirmClose,
    super.closeInstead,
    super.onError,
  }) : super(
         persistence: _WindowBoundsPersistence(preferences),
         closePolicy: GhostClosePolicy.intercept,
         missingMonitor: MissingMonitorPolicy.clampToNearest,
         // D32 §3: the unified toolbar goes in while the window is still
         // hidden, so the standard titlebar never flashes first.
         onMacosPrepare: (titlebar ?? const _MacTitlebarAdapter()).initialize,
         windowDefaults: const GhostWindowOptions(
           size: _initialWindowSize,
           minimumSize: _minimumContentSize,
         ),
         minimumContentSize: _minimumContentSize,
       );
}

final class _MacTitlebarAdapter implements MacTitlebarAdapter {
  const _MacTitlebarAdapter();

  @override
  Future<void> initialize() async {
    await WindowManipulator.initialize();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.hideTitle();
    // D32 §3: an empty unified toolbar makes the titlebar band 52 pt
    // tall, so the traffic lights sit centered on the Flutter header
    // drawn beneath it (Finder/ForkLift geometry). Empty areas keep the
    // native drag and double-click-to-zoom; the header wraps its
    // controls in MacosToolbarPassthrough so clicks reach Flutter, and
    // every other surface stays below the band (ReserveMacosToolbarBand).
    await WindowManipulator.addToolbar();
    await WindowManipulator.setToolbarStyle(
      toolbarStyle: NSWindowToolbarStyle.unified,
    );
  }
}

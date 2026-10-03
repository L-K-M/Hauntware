import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'snapshot.dart';

/// The persistence seam each host owns. The stored shape, file location,
/// atomicity, and tolerated corruption are the host's — the lifecycle only
/// ever sees whole snapshots. A host that stores bounds alone (Poltergeist)
/// simply ignores the presentation flags on save and answers them false on
/// load.
abstract interface class GhostWindowPersistence {
  Future<GhostWindowSnapshot?> load();

  Future<void> save(GhostWindowSnapshot snapshot);
}

/// The windowing operations the lifecycle needs, over window_manager's API
/// surface. Provided so tests can script the native side, and so a host can
/// substitute its own channel (Poltergeist's native workspace windows drive
/// secondary windows through a different host entirely — this adapter is for
/// the primary window only).
abstract interface class GhostWindowAdapter {
  Future<void> ensureInitialized();

  /// Applies the pre-show options (size, placement, size limits, title,
  /// backdrop) the runner does not already provide. Never shows the window.
  Future<void> waitUntilReadyToShow(GhostWindowOptions? options);

  /// [bounds] is a full frame; [position] alone moves without resizing.
  /// Values are logical pixels — the lifecycle converts out of the stored
  /// space first when the host stores physical pixels.
  Future<void> setBounds(Rect? bounds, {Offset? position});

  Future<Rect> getBounds();

  Future<void> setMinimumSize(Size size);

  /// window_manager's synchronous ratio for the monitor the window is on
  /// right now. Only consulted on Windows under
  /// [GhostCoordinateSpace.physicalOnWindows].
  double getDevicePixelRatio();

  Future<bool> isMinimized();

  Future<bool> isMaximized();

  Future<bool> isFullScreen();

  Future<void> maximize();

  Future<void> setFullScreen(bool fullScreen);

  Future<void> show();

  Future<void> focus();

  /// window_manager's `setPreventClose`: under
  /// [GhostClosePolicy.intercept] a native close is delivered as
  /// [GhostWindowListener.onWindowClose] and the window stays up until the
  /// lifecycle destroys it.
  Future<void> setPreventClose(bool prevent);

  Future<void> destroy();

  /// One listener at a time is the contract the lifecycle relies on;
  /// implementations may support more.
  void addListener(GhostWindowListener listener);

  void removeListener(GhostWindowListener listener);
}

/// Window events, at window_manager's granularity. All callbacks are no-ops
/// so a listener only overrides what it needs.
abstract base class GhostWindowListener {
  const GhostWindowListener();

  /// The window became visible — on Windows the deferred restore flags wait
  /// for it (the runners show the window themselves on the first frame).
  void onWindowShow() {}

  /// Move and resize are conflated deliberately: every event only schedules
  /// the same debounced capture. Adapters fold the `*ed` variants in here
  /// too, since the two spellings fire on different platforms.
  void onWindowMove() {}

  void onWindowResize() {}

  void onWindowMaximize() {}

  void onWindowUnmaximize() {}

  void onWindowEnterFullScreen() {}

  void onWindowLeaveFullScreen() {}

  void onWindowRestore() {}

  /// Native close request. Under [GhostClosePolicy.intercept] the window is
  /// still up and the lifecycle decides; under [GhostClosePolicy.observe]
  /// the window is already going away and this is only the last chance to
  /// persist.
  void onWindowClose() {}
}

/// A connected display, as the lifecycle needs it. [workArea] is the visible
/// working area in the display's own logical pixels; [scaleFactor] converts
/// it into physical pixels for hosts storing those on Windows.
final class GhostDisplay {
  const GhostDisplay({required this.workArea, this.scaleFactor = 1});

  final Rect workArea;
  final double scaleFactor;
}

abstract interface class GhostDisplayAdapter {
  Future<GhostDisplay> primaryDisplay();

  Future<List<GhostDisplay>> displays();
}

/// What the host wants the window to look like before any restore applies —
/// the runner's fallback when nothing was saved. [placement] distinguishes
/// "use the platform default position" (centered) from "a saved frame was
/// applied" (restored), which hosts echo in their tests.
final class GhostWindowOptions {
  const GhostWindowOptions({
    required this.size,
    this.placement = GhostWindowPlacement.centered,
    this.minimumSize,
    this.title,
    this.backgroundColor,
  });

  final Size size;
  final GhostWindowPlacement placement;
  final Size? minimumSize;

  /// The pre-paint window title and backdrop. A backdrop left unset shows
  /// the platform default, which reads as a white flash on a dark desktop.
  final String? title;
  final Color? backgroundColor;
}

enum GhostWindowPlacement { centered, restored }

/// window_manager over the primary window.
final class WindowManagerGhostWindowAdapter
    with WindowListener
    implements GhostWindowAdapter {
  WindowManagerGhostWindowAdapter();

  final _listeners = <GhostWindowListener>{};

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  Future<void> waitUntilReadyToShow(GhostWindowOptions? options) {
    return windowManager.waitUntilReadyToShow(
      options == null
          ? null
          : WindowOptions(
              size: options.size,
              center: options.placement == GhostWindowPlacement.centered,
              minimumSize: options.minimumSize,
              title: options.title,
              backgroundColor: options.backgroundColor,
            ),
    );
  }

  @override
  Future<void> setBounds(Rect? bounds, {Offset? position}) =>
      windowManager.setBounds(bounds, position: position);

  @override
  Future<Rect> getBounds() => windowManager.getBounds();

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  double getDevicePixelRatio() => windowManager.getDevicePixelRatio();

  @override
  Future<bool> isMinimized() => windowManager.isMinimized();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> setFullScreen(bool fullScreen) =>
      windowManager.setFullScreen(fullScreen);

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> setPreventClose(bool prevent) =>
      windowManager.setPreventClose(prevent);

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  void addListener(GhostWindowListener listener) {
    if (_listeners.add(listener) && _listeners.length == 1) {
      windowManager.addListener(this);
    }
  }

  @override
  void removeListener(GhostWindowListener listener) {
    if (_listeners.remove(listener) && _listeners.isEmpty) {
      windowManager.removeListener(this);
    }
  }

  @override
  void onWindowEvent(String eventName) {
    // window_manager's native side emits 'show' (the Linux plugin on the
    // GtkWidget signal, Windows on WM_SHOWWINDOW); only the raw eventName
    // path reaches it — the named-callback table has no show entry.
    if (eventName == 'show') {
      // _forEach copies the set: a listener may not unsubscribe itself
      // mid-dispatch.
      _forEach((l) => l.onWindowShow());
    }
  }

  @override
  void onWindowMove() => _forEach((l) => l.onWindowMove());
  @override
  void onWindowMoved() => _forEach((l) => l.onWindowMove());
  @override
  void onWindowResize() => _forEach((l) => l.onWindowResize());
  @override
  void onWindowResized() => _forEach((l) => l.onWindowResize());
  @override
  void onWindowMaximize() => _forEach((l) => l.onWindowMaximize());
  @override
  void onWindowUnmaximize() => _forEach((l) => l.onWindowUnmaximize());
  @override
  void onWindowEnterFullScreen() =>
      _forEach((l) => l.onWindowEnterFullScreen());
  @override
  void onWindowLeaveFullScreen() =>
      _forEach((l) => l.onWindowLeaveFullScreen());
  @override
  void onWindowRestore() => _forEach((l) => l.onWindowRestore());
  @override
  void onWindowClose() => _forEach((l) => l.onWindowClose());

  void _forEach(void Function(GhostWindowListener) action) {
    for (final listener in _listeners.toList()) {
      action(listener);
    }
  }
}

/// screen_retriever over all connected displays.
final class ScreenRetrieverGhostDisplayAdapter implements GhostDisplayAdapter {
  const ScreenRetrieverGhostDisplayAdapter();

  @override
  Future<GhostDisplay> primaryDisplay() async =>
      _convert(await screenRetriever.getPrimaryDisplay());

  @override
  Future<List<GhostDisplay>> displays() async =>
      (await screenRetriever.getAllDisplays()).map(_convert).toList();

  static GhostDisplay _convert(Display display) => GhostDisplay(
    workArea:
        (display.visiblePosition ?? Offset.zero) &
        (display.visibleSize ?? display.size),
    scaleFactor: (display.scaleFactor ?? 1).toDouble(),
  );
}

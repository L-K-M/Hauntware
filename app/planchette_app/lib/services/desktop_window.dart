import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps both native close routes behind the workspace's shared dirty guard.
final class DesktopWindow with WindowListener {
  DesktopWindow({
    required this.confirmQuit,
    required this.onQuitFailed,
    this.onFocus,
    this.closeInstead,
    this.windowBackgroundColor,
    Future<void> Function()? destroyWindow,
    Future<void> Function(String title)? setWindowTitle,
  }) : _destroyWindow = destroyWindow ?? windowManager.destroy,
       _setWindowTitle = setWindowTitle ?? windowManager.setTitle;
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
  final Future<void> Function() _destroyWindow;
  final Future<void> Function(String title) _setWindowTitle;
  AppLifecycleListener? _lifecycle;
  bool _destroying = false;
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

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        return await confirmQuit()
            ? AppExitResponse.exit
            : AppExitResponse.cancel;
      },
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Future<void> requestQuit() async {
    if (_destroying) return;
    _destroying = true;
    try {
      if (!await confirmQuit()) return;
      await _destroyWindow();
    } catch (error) {
      onQuitFailed(error);
    } finally {
      _destroying = false;
    }
  }

  @override
  void onWindowClose() => unawaited(_close());

  /// A second close event while the first is still deciding must not run
  /// again: it would find the window already hidden and read it as the
  /// last one, quitting the app over two open windows.
  bool _closeRunning = false;

  Future<void> _close() async {
    if (_destroying || _closeRunning) return;
    _closeRunning = true;
    try {
      if (await closeInstead?.call() ?? false) return;
      await requestQuit();
    } finally {
      _closeRunning = false;
    }
  }

  @override
  void onWindowFocus() => onFocus?.call();

  /// Each call is a platform channel message; skip the ones that would not
  /// change what the window shows.
  void setTitle(String title) {
    if (title == _title) return;
    _title = title;
    unawaited(
      _setWindowTitle(title).catchError((Object _) {
        // Forget a title that never arrived so the next request retries it.
        if (title == _title) _title = null;
      }),
    );
  }

  void dispose() {
    windowManager.removeListener(this);
    _lifecycle?.dispose();
  }
}

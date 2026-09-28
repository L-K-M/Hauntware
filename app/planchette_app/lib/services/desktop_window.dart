import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps both native close routes behind the workspace's shared dirty guard.
final class DesktopWindow with WindowListener {
  DesktopWindow({
    required this.confirmQuit,
    required this.onQuitFailed,
    this.windowBackgroundColor,
    Future<void> Function()? destroyWindow,
    Future<void> Function(String title)? setWindowTitle,
  }) : _destroyWindow = destroyWindow ?? windowManager.destroy,
       _setWindowTitle = setWindowTitle ?? windowManager.setTitle;
  final Future<bool> Function() confirmQuit;
  final void Function(Object error) onQuitFailed;

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
  void onWindowClose() => unawaited(requestQuit());

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

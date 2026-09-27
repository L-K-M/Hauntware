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
    Future<void> Function()? destroyWindow,
  }) : _destroyWindow = destroyWindow ?? windowManager.destroy;
  final Future<bool> Function() confirmQuit;
  final void Function(Object error) onQuitFailed;

  /// Called when the window becomes active again, for example to notice
  /// files that other programs changed in the meantime.
  final void Function()? onFocus;
  final Future<void> Function() _destroyWindow;
  AppLifecycleListener? _lifecycle;
  bool _destroying = false;

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
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1080, 760),
        minimumSize: Size(640, 400),
        center: true,
        title: 'Planchette',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
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

  @override
  void onWindowFocus() => onFocus?.call();

  void setTitle(String title) => unawaited(windowManager.setTitle(title));

  void dispose() {
    windowManager.removeListener(this);
    _lifecycle?.dispose();
  }
}

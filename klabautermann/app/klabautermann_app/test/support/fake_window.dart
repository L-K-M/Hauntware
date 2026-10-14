import 'dart:ui';

import 'package:ghost_desktop/ghost_desktop.dart';

/// A scripted main window for the window-state tests: every native call
/// lands in [calls], geometry and flags are plain fields, and `emit*`
/// drives the listener the way window_manager delivers its events.
final class FakeWindow implements GhostWindowAdapter {
  final calls = <String>[];
  final boundsSet = <Rect>[];
  Rect bounds = const Rect.fromLTWH(100, 100, 1280, 720);
  bool minimized = false;
  bool maximized = false;
  bool fullScreen = false;
  bool preventClose = false;
  double devicePixelRatio = 1;
  bool failEnsureInitialized = false;
  GhostWindowListener? _listener;

  bool get listening => _listener != null;

  @override
  Future<void> ensureInitialized() async {
    calls.add('ensureInitialized');
    if (failEnsureInitialized) throw StateError('no window plugin');
  }

  @override
  Future<void> waitUntilReadyToShow(GhostWindowOptions? options) async {
    calls.add('waitUntilReadyToShow');
  }

  @override
  Future<void> setBounds(Rect? value, {Offset? position}) async {
    calls.add('setBounds');
    if (position != null) {
      bounds = position & bounds.size;
    }
    if (value != null) {
      bounds = value;
      boundsSet.add(value);
    }
  }

  @override
  Future<Rect> getBounds() async => bounds;

  @override
  Future<void> setMinimumSize(Size size) async => calls.add('setMinimumSize');

  @override
  double getDevicePixelRatio() => devicePixelRatio;

  @override
  Future<bool> isMinimized() async => minimized;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
  }

  @override
  Future<void> setFullScreen(bool value) async {
    calls.add('setFullScreen($value)');
    fullScreen = value;
  }

  @override
  Future<void> show() async => calls.add('show');

  @override
  Future<void> focus() async => calls.add('focus');

  @override
  Future<void> setPreventClose(bool prevent) async {
    calls.add('setPreventClose($prevent)');
    preventClose = prevent;
  }

  @override
  Future<void> destroy() async => calls.add('destroy');

  @override
  void addListener(GhostWindowListener listener) => _listener = listener;

  @override
  void removeListener(GhostWindowListener listener) {
    if (identical(_listener, listener)) _listener = null;
  }

  void emitMove() => _listener?.onWindowMove();
  void emitMaximize() => _listener?.onWindowMaximize();
  void emitClose() => _listener?.onWindowClose();
}

/// The connected displays: [primary] first, then [others].
final class FakeDisplays implements GhostDisplayAdapter {
  FakeDisplays(this.primary, [this.others = const []]);

  final GhostDisplay primary;
  final List<GhostDisplay> others;

  @override
  Future<GhostDisplay> primaryDisplay() async => primary;

  @override
  Future<List<GhostDisplay>> displays() async => [primary, ...others];
}

/// Persistence in memory, recording every save.
final class MemoryWindowState implements GhostWindowPersistence {
  MemoryWindowState([this.stored]);

  GhostWindowSnapshot? stored;
  final saves = <GhostWindowSnapshot>[];

  @override
  Future<GhostWindowSnapshot?> load() async => stored;

  @override
  Future<void> save(GhostWindowSnapshot snapshot) async {
    stored = snapshot;
    saves.add(snapshot);
  }
}

/// A debounce the test fires by hand: [pending] holds the scheduled
/// callbacks until [flush] runs them.
final class ManualDebounce {
  final pending = <Future<void> Function()>[];

  void Function() call(Duration _, Future<void> Function() callback) {
    pending.add(callback);
    return () => pending.remove(callback);
  }

  Future<void> flush() async {
    final due = [...pending];
    pending.clear();
    for (final callback in due) {
      await callback();
    }
  }
}

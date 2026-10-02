import 'dart:async';
import 'dart:ui';

import 'package:ghost_desktop/ghost_desktop.dart';

/// Scripted adapters for [GhostWindowLifecycle] tests: every native call
/// records into [events] and block/fail switches let a test hold or break
/// any stage. `emit*` methods drive the listener callbacks the way
/// `window_manager` delivers them.
final class FakeWindowAdapter implements GhostWindowAdapter {
  int ensureInitializedCalls = 0;
  bool failEnsureInitialized = false;
  bool blockEnsureInitialized = false;
  bool failShow = false;
  bool failDestroy = false;
  bool failSetMinimumSize = false;
  bool failSetBounds = false;
  bool blockReadyToShow = false;
  bool blockGetBounds = false;
  bool preventClose = false;
  bool listenerRegistered = false;
  bool destroyed = false;
  bool minimized = false;
  bool maximized = false;
  bool fullScreen = false;
  double devicePixelRatio = 1;
  Rect bounds = const Rect.fromLTWH(80, 60, 1180, 760);
  Size? minimumSize;
  final minimumSizes = <Size>[];
  final callsAfterDestroy = <String>[];
  GhostWindowOptions? readyOptions;
  final events = <String>[];
  final ensureInitializedStarted = Completer<void>();
  final readyToShowStarted = Completer<void>();
  final getBoundsStarted = Completer<void>();
  Completer<void>? _readyToShowRelease;
  Completer<void>? _ensureInitializedRelease;
  Completer<void>? _getBoundsRelease;
  GhostWindowListener? _listener;

  @override
  Future<void> ensureInitialized() async {
    ensureInitializedCalls++;
    if (!ensureInitializedStarted.isCompleted) {
      ensureInitializedStarted.complete();
    }
    if (blockEnsureInitialized) {
      _ensureInitializedRelease ??= Completer<void>();
      await _ensureInitializedRelease!.future;
    }
    if (failEnsureInitialized) throw StateError('initialization failed');
  }

  @override
  Future<Rect> getBounds() async {
    _recordCall('getBounds');
    if (!getBoundsStarted.isCompleted) getBoundsStarted.complete();
    if (blockGetBounds) {
      _getBoundsRelease ??= Completer<void>();
      await _getBoundsRelease!.future;
    }
    return bounds;
  }

  @override
  Future<void> setBounds(Rect? value, {Offset? position}) async {
    _recordCall('setBounds');
    if (failSetBounds) throw StateError('setBounds failed');
    if (position != null) {
      bounds = Rect.fromLTWH(
        position.dx,
        position.dy,
        bounds.width,
        bounds.height,
      );
      events.add('position');
    }
    if (value != null) {
      bounds = value;
      events.add('bounds');
    }
  }

  @override
  Future<void> setMinimumSize(Size value) async {
    _recordCall('setMinimumSize');
    if (failSetMinimumSize) throw StateError('minimum size failed');
    minimumSize = value;
    minimumSizes.add(value);
  }

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
    _recordCall('maximize');
    maximized = true;
    events.add('maximize');
  }

  @override
  Future<void> setFullScreen(bool value) async {
    _recordCall('setFullScreen');
    fullScreen = value;
    events.add('fullScreen');
  }

  @override
  Future<void> setPreventClose(bool prevent) async {
    _recordCall('setPreventClose');
    preventClose = prevent;
  }

  @override
  Future<void> waitUntilReadyToShow(GhostWindowOptions? options) async {
    _recordCall('waitUntilReadyToShow');
    readyOptions = options;
    events.add('ready');
    if (!readyToShowStarted.isCompleted) readyToShowStarted.complete();
    if (!blockReadyToShow) return;

    _readyToShowRelease ??= Completer<void>();
    await _readyToShowRelease!.future;
  }

  @override
  Future<void> show() async {
    _recordCall('show');
    if (failShow) throw StateError('show failed');
    events.add('show');
  }

  @override
  Future<void> focus() async {
    _recordCall('focus');
    events.add('focus');
  }

  @override
  Future<void> destroy() async {
    _recordCall('destroy');
    if (failDestroy) throw StateError('destroy failed');
    events.add('destroy');
    destroyed = true;
  }

  @override
  void addListener(GhostWindowListener listener) {
    _recordCall('addListener');
    listenerRegistered = true;
    _listener = listener;
  }

  @override
  void removeListener(GhostWindowListener listener) {
    if (identical(_listener, listener)) _listener = null;
    listenerRegistered = false;
  }

  void emitMove() => _listener?.onWindowMove();
  void emitResize() => _listener?.onWindowResize();
  void emitClose() => _listener?.onWindowClose();
  void emitShow() => _listener?.onWindowShow();
  void emitMaximize() => _listener?.onWindowMaximize();

  // Releases are one-shot and idempotent: the gate drops its completer
  // and clears the block flag, so a second release is a no-op and the
  // gate can never re-park on a stale completer.
  void releaseReadyToShow() {
    final release = _readyToShowRelease;
    _readyToShowRelease = null;
    blockReadyToShow = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseEnsureInitialized() {
    final release = _ensureInitializedRelease;
    _ensureInitializedRelease = null;
    blockEnsureInitialized = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseGetBounds() {
    final release = _getBoundsRelease;
    _getBoundsRelease = null;
    blockGetBounds = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void _recordCall(String call) {
    if (destroyed) callsAfterDestroy.add(call);
  }
}

final class FakeDisplayAdapter implements GhostDisplayAdapter {
  FakeDisplayAdapter({
    this.primary = const GhostDisplay(
      workArea: Rect.fromLTWH(0, 0, 1920, 1040),
    ),
    this.all = const [GhostDisplay(workArea: Rect.fromLTWH(0, 0, 1920, 1040))],
  });

  GhostDisplay primary;
  List<GhostDisplay> all;

  @override
  Future<GhostDisplay> primaryDisplay() async => primary;

  @override
  Future<List<GhostDisplay>> displays() async => all;
}

/// In-memory persistence recording every snapshot it was asked to write.
final class MemoryPersistence implements GhostWindowPersistence {
  MemoryPersistence([this.stored]);

  GhostWindowSnapshot? stored;
  final writes = <GhostWindowSnapshot>[];
  bool failWrites = false;
  bool blockWrites = false;
  final writeStarted = Completer<void>();
  Completer<void>? _release;

  @override
  Future<GhostWindowSnapshot?> load() async => stored;

  @override
  Future<void> save(GhostWindowSnapshot snapshot) async {
    writes.add(snapshot);
    if (!writeStarted.isCompleted) writeStarted.complete();
    if (blockWrites) {
      _release ??= Completer<void>();
      await _release!.future;
    }
    if (failWrites) throw StateError('write failed');
    stored = snapshot;
  }

  void releaseWrites() {
    final release = _release;
    _release = null;
    blockWrites = false;
    if (release != null && !release.isCompleted) release.complete();
  }
}

final class FakeDebounceScheduler {
  int cancelCount = 0;
  Duration? lastDelay;
  final _activeCallbacks = <Future<void> Function()>{};

  void Function() schedule(Duration delay, Future<void> Function() callback) {
    lastDelay = delay;
    _activeCallbacks.add(callback);
    return () {
      if (_activeCallbacks.remove(callback)) cancelCount++;
    };
  }

  Future<void> fire() async {
    final pending = _activeCallbacks.toList(growable: false);
    _activeCallbacks.clear();
    for (final callback in pending) {
      await callback();
    }
  }
}

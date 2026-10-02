// Host-facing named parameters keep their names while the fields stay
// private — the same seam Poltergeist's lifecycle kept private.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'adapters.dart';
import 'geometry.dart';
import 'snapshot.dart';

/// The close-path session flush's bound (Poltergeist 02 §3): the intercepted
/// close is the last guaranteed wait, but a wedged write must still let the
/// window destroy — same posture as `onExitRequested`'s flush timeout.
const _closeFlushTimeout = Duration(seconds: 2);

/// Windows: if the runner's first-frame Show never reaches the plugin's
/// 'show' event, the deferred restore flags apply anyway after this.
const _windowsFlagsBackstop = Duration(seconds: 3);

const _defaultGeometrySaveDelay = Duration(milliseconds: 250);

void Function() _scheduleWithTimer(
  Duration delay,
  Future<void> Function() callback,
) {
  final timer = Timer(delay, () => callback().ignore());
  return timer.cancel;
}

enum GhostDesktopPlatform { other, linux, macos, windows }

/// The coordinate space [GhostWindowSnapshot.bounds] is stored in. window_
/// manager speaks logical pixels everywhere; on Windows it converts with the
/// ratio of the monitor the window is on *right now*, which makes logical
/// pixels unstable across a mixed-DPI relaunch. Hosts that launched storing
/// physical pixels on Windows keep doing so — the file's meaning is fixed.
enum GhostCoordinateSpace { logical, physicalOnWindows }

/// What a saved frame that no longer fits any connected display becomes.
/// [rejectAndKeep] falls back to the platform's default placement but keeps
/// the frame on record — if the monitor comes back next launch, the window
/// goes home. [clampToNearest] rewrites it onto the closest display now.
enum MissingMonitorPolicy { rejectAndKeep, clampToNearest }

/// Who owns the native close signal. [intercept] sets prevent-close so the
/// lifecycle can run its guarded close path (Poltergeist, Planchette);
/// [observe] leaves the close alone and treats the event as a last-chance
/// persist (Séance — its close is not guarded).
enum GhostClosePolicy { intercept, observe }

/// Who makes the window visible on Windows and Linux, where the stock
/// runners show it themselves on the first Flutter frame. [runner] is for
/// hosts restoring before `runApp` (Séance): asking for the window early
/// would show it unpainted. [service] is for hosts whose show runs after
/// `runApp` (Poltergeist). macOS is exempt: its hidden-at-launch contract
/// means only the lifecycle can ever show the window.
enum GhostShowTrigger { service, runner }

/// Restores the remembered window state at launch and keeps it current while
/// the app runs. Desktop only — a no-op on other platforms.
///
/// This one object merges what were Séance's `WindowStateService` (frame and
/// presentation flags, missing-monitor fallback, physical-pixel Windows
/// space, observed native close) and Poltergeist's `DesktopWindowLifecycle`
/// (serialized window operations, guarded intercepted close, content-size
/// calibration, work-area clamping). Which half is active is configuration,
/// so both hosts run the same code path end to end.
///
/// Scope: the primary window only. Hosts with more windows (Poltergeist's
/// workspace windows, Planchette's document windows) place those through
/// their own host channels and never reach this service.
///
/// Wiring contract (macOS): the host's runner keeps the window hidden at
/// launch (`hiddenWindowAtLaunch()` in the window's `order` override) so the
/// saved frame applies off-screen. [show] is what makes it visible again —
/// it always reaches `show()` even when restoring failed — so it must run
/// unconditionally once per launch.
base class GhostWindowLifecycle extends GhostWindowListener {
  GhostWindowLifecycle({
    required GhostWindowPersistence persistence,
    required GhostClosePolicy closePolicy,
    required MissingMonitorPolicy missingMonitor,
    GhostWindowAdapter? window,
    GhostDisplayAdapter? displays,
    GhostDesktopPlatform? platform,
    GhostCoordinateSpace coordinates = GhostCoordinateSpace.logical,
    GhostShowTrigger showTrigger = GhostShowTrigger.service,
    GhostWindowOptions? windowDefaults,
    Size? minimumContentSize,
    Future<void> Function()? onMacosPrepare,
    Duration geometrySaveDelay = _defaultGeometrySaveDelay,
    void Function() Function(Duration, Future<void> Function())?
    scheduleDebounce,
    Future<void> Function()? onCloseFlush,
    Future<bool> Function()? confirmClose,
    Future<bool> Function()? closeInstead,
    void Function(Object, StackTrace)? onError,
  }) : _persistence = persistence,
       _window = window ?? WindowManagerGhostWindowAdapter(),
       _displays = displays ?? const ScreenRetrieverGhostDisplayAdapter(),
       _platform = platform ?? _currentPlatform(),
       _closePolicy = closePolicy,
       _missingMonitor = missingMonitor,
       _coordinates = coordinates,
       _showTrigger = showTrigger,
       _windowDefaults = windowDefaults,
       _minimumContentSize = minimumContentSize,
       _onMacosPrepare = onMacosPrepare,
       _geometrySaveDelay = geometrySaveDelay,
       _scheduleDebounce = scheduleDebounce ?? _scheduleWithTimer,
       _onCloseFlush = onCloseFlush,
       _confirmClose = confirmClose,
       _closeInstead = closeInstead,
       _onError = onError;

  final GhostWindowPersistence _persistence;
  final GhostWindowAdapter _window;
  final GhostDisplayAdapter _displays;
  final GhostDesktopPlatform _platform;
  final GhostClosePolicy _closePolicy;
  final MissingMonitorPolicy _missingMonitor;
  final GhostCoordinateSpace _coordinates;
  final GhostShowTrigger _showTrigger;
  final GhostWindowOptions? _windowDefaults;

  /// The content minimum calibration enforces, in logical pixels: the
  /// smallest area the first frame may report before the window is grown to
  /// fit it (Poltergeist's 720x480). Null disables calibration.
  final Size? _minimumContentSize;

  /// macOS-only prepare step — Poltergeist installs its unified titlebar
  /// while the window is still hidden so the standard one never flashes.
  final Future<void> Function()? _onMacosPrepare;
  final Duration _geometrySaveDelay;
  final void Function() Function(Duration, Future<void> Function())
  _scheduleDebounce;

  /// The app-quit safe point: the session document's flush hook, awaited
  /// inside [_close] after the geometry save and before the window destroys —
  /// the intercepted close is the only quit path where a wait is guaranteed,
  /// so the last session write lands here.
  final Future<void> Function()? _onCloseFlush;

  /// The quit gate: consulted inside [_close] before anything else — false
  /// vetoes the close and the window stays up. Null means nothing guards the
  /// close.
  final Future<bool> Function()? _confirmClose;

  /// With other windows open, the close button closes this window only.
  /// Consulted before the quit guard; true means it took the close (the
  /// window is hidden, not destroyed) and the quit path does not run.
  final Future<bool> Function()? _closeInstead;
  final void Function(Object, StackTrace)? _onError;

  final _windowReady = Completer<void>();

  /// Resolves once the platform window has finished
  /// `waitUntilReadyToShow`: the point after which window_manager's
  /// per-window native state exists (on Windows, the taskbar list its
  /// `setProgressBar` dereferences unchecked). Never resolves when
  /// prepare or show failed first, so a caller gated on it simply stays
  /// idle instead of reaching a half-initialized plugin.
  Future<void> get windowReady => _windowReady.future;

  GhostWindowSnapshot _current = const GhostWindowSnapshot();
  Rect? _restoredBounds;
  void Function()? _cancelScheduledSave;
  void Function()? _cancelFlagsBackstop;
  Future<void> _windowTail = Future.value();
  Future<void>? _prepareFuture;
  Future<bool>? _closeFuture;
  Size? _calibratedContentSize;
  var _prepared = false;
  var _closing = false;
  var _calibrationRevision = 0;

  static GhostDesktopPlatform _currentPlatform() {
    if (Platform.isMacOS) return GhostDesktopPlatform.macos;
    if (Platform.isWindows) return GhostDesktopPlatform.windows;
    if (Platform.isLinux) return GhostDesktopPlatform.linux;
    return GhostDesktopPlatform.other;
  }

  Future<void> prepare() {
    if (_platform == GhostDesktopPlatform.other || _prepared || _closing) {
      return Future.value();
    }

    return _prepareFuture ??= _prepare().whenComplete(() {
      _prepareFuture = null;
    });
  }

  Future<void> _prepare() async {
    try {
      await _window.ensureInitialized();
      if (_closing) return;

      if (_platform == GhostDesktopPlatform.macos) {
        await _onMacosPrepare?.call();
        if (_closing) return;
      }

      final saved = await _persistence.load();
      if (_closing) return;

      final displays = await _displays.displays();
      if (_closing) return;

      final savedBounds = saved?.bounds;
      if (savedBounds != null) {
        _restoredBounds = switch (_missingMonitor) {
          MissingMonitorPolicy.rejectAndKeep => resolveRestorableFrame(
            savedBounds,
            [for (final display in displays) _storedArea(display)],
          ),
          MissingMonitorPolicy.clampToNearest => clampFrameToWorkArea(
            bounds: savedBounds,
            workAreas: [for (final display in displays) _storedArea(display)],
            fallbackWorkArea: _storedArea(await _displays.primaryDisplay()),
          ),
        };
        if (_closing) return;
      }

      // A rejected saved frame (its monitor is disconnected) is deliberately
      // retained, not dropped: every restore re-checks it against the
      // connected displays, so it can never place the window off-screen —
      // but if that monitor comes back, the window goes home. The first
      // normal-frame capture replaces it anyway.
      _current = GhostWindowSnapshot(
        bounds: _restoredBounds ?? savedBounds,
        isMaximized: saved?.isMaximized ?? false,
        isFullScreen: saved?.isFullScreen ?? false,
      );

      _window.addListener(this);
      if (_closePolicy == GhostClosePolicy.intercept) {
        await _window.setPreventClose(true);
        if (_closing) return;
      }

      _prepared = true;
    } catch (_) {
      _window.removeListener(this);
      rethrow;
    }
  }

  Future<void> show() async {
    if (!_prepared || _closing) {
      // macOS runners hide the window at launch for this service to place
      // it. A launch that never gets here (failed prepare) must not leave
      // the app invisible — but a window already closing stays on its way
      // down.
      if (!_closing) await _rescueHiddenWindow();
      return;
    }

    await _enqueueWindowOperation(() async {
      if (_closing) return;

      await _window.waitUntilReadyToShow(_effectiveOptions());
      if (!_windowReady.isCompleted) _windowReady.complete();
      if (_closing) return;

      try {
        await _applyRestored();
      } catch (_) {
        await _rescueHiddenWindow();
        rethrow;
      }
    });
  }

  /// The hidden macOS window's unconditional exit path: whatever failed
  /// above, the app still appears.
  Future<void> _rescueHiddenWindow() async {
    if (_platform != GhostDesktopPlatform.macos) return;
    try {
      await _window.show();
      await _window.focus();
    } catch (_) {}
  }

  GhostWindowOptions? _effectiveOptions() {
    final defaults = _windowDefaults;
    if (defaults == null) return null;
    final restored = _restoredBounds;
    return GhostWindowOptions(
      size: restored == null ? defaults.size : _toLogicalSpace(restored).size,
      placement: restored == null
          ? defaults.placement
          : GhostWindowPlacement.restored,
      minimumSize: defaults.minimumSize,
      title: defaults.title,
      backgroundColor: defaults.backgroundColor,
    );
  }

  /// Per-platform show sequence — the ordering each runner was built around:
  /// macOS applies everything while hidden and ends with show+focus (full
  /// screen last: toggleFullScreen does nothing to a hidden window); Windows
  /// parks maximize/full-screen until the runner's own first-frame Show
  /// delivers the 'show' event, since SW_SHOWNORMAL would cancel them;
  /// Linux's pre-map requests take effect when the window maps.
  Future<void> _applyRestored() async {
    final bounds = _restoredBounds;
    final maximized = _current.isMaximized;
    final fullScreen = _current.isFullScreen;
    switch (_platform) {
      case GhostDesktopPlatform.macos:
        if (bounds != null) {
          await _window.setBounds(_toLogicalSpace(bounds));
        }
        if (maximized && !fullScreen) await _window.maximize();
        await _window.show();
        await _window.focus();
        if (fullScreen) await _window.setFullScreen(true);
      case GhostDesktopPlatform.windows:
        if (bounds != null) {
          final logical = _toLogicalSpace(bounds);
          // Two passes: crossing onto a different-DPI monitor makes the
          // runner apply the OS's suggested frame (WM_DPICHANGED — handled
          // synchronously inside the first call), which rescales the window.
          // Re-asserting the full frame afterwards sticks exactly.
          await _window.setBounds(null, position: logical.topLeft);
          await _window.setBounds(logical);
        }
        if (maximized || fullScreen) {
          _pendingWindowsFlags = (maximized: maximized, fullScreen: fullScreen);
          _cancelFlagsBackstop = _scheduleDebounce(
            _windowsFlagsBackstop,
            _applyPendingWindowsFlags,
          );
        }
        if (_showTrigger == GhostShowTrigger.service) {
          await _window.show();
          await _window.focus();
        }
      case GhostDesktopPlatform.linux:
        if (bounds != null) await _window.setBounds(_toLogicalSpace(bounds));
        if (fullScreen) {
          await _window.setFullScreen(true);
        } else if (maximized) {
          await _window.maximize();
        }
        if (_showTrigger == GhostShowTrigger.service) {
          await _window.show();
          await _window.focus();
        }
      case GhostDesktopPlatform.other:
        break;
    }
  }

  /// Windows-only: maximize/full-screen waiting for the runner to show the
  /// window (see the Windows branch of [_applyRestored]).
  ({bool maximized, bool fullScreen})? _pendingWindowsFlags;

  Future<void> _applyPendingWindowsFlags() async {
    _cancelFlagsBackstop?.call();
    _cancelFlagsBackstop = null;
    final pending = _pendingWindowsFlags;
    if (pending == null) return;
    _pendingWindowsFlags = null;
    try {
      if (pending.fullScreen) {
        await _window.setFullScreen(true);
      } else if (pending.maximized) {
        await _window.maximize();
      }
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  Future<void> calibrateMinimumSize(Size contentSize) async {
    final minimumContentSize = _minimumContentSize;
    if (!_prepared ||
        _closing ||
        minimumContentSize == null ||
        contentSize == _calibratedContentSize ||
        !_isFinitePositive(contentSize)) {
      return;
    }

    final revision = ++_calibrationRevision;
    await _enqueueWindowOperation(() async {
      if (!_isCurrentCalibration(revision)) return;

      try {
        final outerBounds = await _window.getBounds();
        if (!_isCurrentCalibration(revision)) return;

        final frameSize = Size(
          (outerBounds.width - contentSize.width).clamp(0, double.infinity),
          (outerBounds.height - contentSize.height).clamp(0, double.infinity),
        );
        final minimumSize = Size(
          minimumContentSize.width + frameSize.width,
          minimumContentSize.height + frameSize.height,
        );

        await _window.setMinimumSize(minimumSize);
        if (!_isCurrentCalibration(revision)) return;

        if (outerBounds.width >= minimumSize.width &&
            outerBounds.height >= minimumSize.height) {
          _calibratedContentSize = contentSize;
          return;
        }

        await _window.setBounds(
          Rect.fromLTWH(
            outerBounds.left,
            outerBounds.top,
            outerBounds.width < minimumSize.width
                ? minimumSize.width
                : outerBounds.width,
            outerBounds.height < minimumSize.height
                ? minimumSize.height
                : outerBounds.height,
          ),
        );
        if (_isCurrentCalibration(revision)) {
          _calibratedContentSize = contentSize;
        }
      } catch (error, stack) {
        _report(error, stack);
      }
    });
  }

  /// Runs the close path. Resolves true once the window has destroyed;
  /// false when the close guard vetoed it (the window stays up and the
  /// next close re-runs the whole path, guard included).
  Future<bool> close() {
    final activeClose = _closeFuture;
    if (activeClose != null) return activeClose;

    _closing = true;
    _calibrationRevision++;
    _cancelScheduledSave?.call();
    _cancelScheduledSave = null;
    final closeFuture = _runClose();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<bool> _runClose() async {
    final preparing = _prepareFuture;
    if (preparing != null) {
      try {
        await preparing;
      } catch (_) {
        // Failed preparation must not prevent native teardown.
      }
    }

    final bool closed;
    try {
      closed = await _enqueueWindowOperation(_close);
    } catch (_) {
      _closing = false;
      _closeFuture = null;
      rethrow;
    }
    if (!closed) {
      // A vetoed close is not a failed one: unwind the closing state so
      // the window is fully live again and a later close starts fresh.
      _closing = false;
      _closeFuture = null;
    }
    return closed;
  }

  /// Saves the window's bounds now, behind any window operation in
  /// flight: the app's exit flush, for a quit that does not come through
  /// this window's close (a ⌘Q with several windows, a mobile suspend).
  Future<void> saveBounds() {
    if (!_prepared || _closing) return Future.value();
    _cancelScheduledSave?.call();
    _cancelScheduledSave = null;
    return _enqueueWindowOperation(_captureAndSave);
  }

  // -- Window events ------------------------------------------------------

  @override
  void onWindowShow() => unawaited(_applyPendingWindowsFlags());

  // Geometry events arrive continuously during a drag; the debounce means one
  // write per interaction, not one per pixel.
  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowResize() => _scheduleSave();
  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();
  @override
  void onWindowEnterFullScreen() => _scheduleSave();
  @override
  void onWindowLeaveFullScreen() => _scheduleSave();
  @override
  void onWindowRestore() => _scheduleSave();

  @override
  void onWindowClose() {
    switch (_closePolicy) {
      case GhostClosePolicy.observe:
        // The window is going away regardless — last chance to persist a
        // change still inside the debounce window. Best effort: if the
        // process dies before the write lands, the previous save still holds.
        _cancelScheduledSave?.call();
        _cancelScheduledSave = null;
        unawaited(_captureAndSave());
      case GhostClosePolicy.intercept:
        unawaited(_closeFromCallback());
    }
  }

  // -- Internals ----------------------------------------------------------

  Future<void> _closeFromCallback() async {
    try {
      await close();
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  void _scheduleSave() {
    if (_closing) return;

    _cancelScheduledSave?.call();
    _cancelScheduledSave = _scheduleDebounce(_geometrySaveDelay, () {
      _cancelScheduledSave = null;
      return _enqueueWindowOperation(() async {
        if (_closing) return;
        await _captureAndSave();
      });
    });
  }

  Future<void> _captureAndSave() async {
    try {
      // A minimized window reports junk geometry; whatever was saved before
      // minimizing is still the truth.
      if (await _window.isMinimized()) return;
      final isFullScreen = await _window.isFullScreen();
      final isMaximized = await _window.isMaximized();
      var bounds = _current.bounds;
      // Only a normal frame is worth remembering — maximized/full-screen
      // bounds are derived from the display, and restoring them as the
      // "normal" frame would make un-maximizing a no-op.
      if (!isFullScreen && !isMaximized) {
        bounds = _toStoredSpace(await _window.getBounds());
      }
      _current = GhostWindowSnapshot(
        bounds: bounds,
        isMaximized: isMaximized,
        isFullScreen: isFullScreen,
      );
      await _persistence.save(_current);
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  Future<bool> _close() async {
    // Only this window closing is not a quit: nothing below applies.
    final instead = _closeInstead;
    if (instead != null && await instead()) return false;

    // The quit guard runs first: a veto must leave nothing behind —
    // no bounds save, no flush, no destroy.
    final guard = _confirmClose;
    if (guard != null && !await guard()) return false;

    await _captureAndSave();

    // A wedged or failed flush reports and lets the window destroy —
    // the quit can never be held hostage by a session write.
    try {
      await _onCloseFlush?.call().timeout(_closeFlushTimeout);
    } catch (error, stack) {
      _report(error, stack);
    }

    await _window.destroy();
    _window.removeListener(this);
    return true;
  }

  Future<T> _enqueueWindowOperation<T>(Future<T> Function() operation) {
    // Native window APIs are stateful and must never overlap.
    final result = _windowTail.then((_) => operation());
    _windowTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// A display's work area in the stored coordinate space. Hosts storing
  /// physical pixels on Windows multiply screen_retriever's per-display
  /// logical area by that display's own scale factor — window_manager's
  /// single current-monitor ratio cannot describe a mixed-DPI desktop.
  Rect _storedArea(GhostDisplay display) {
    if (_platform != GhostDesktopPlatform.windows ||
        _coordinates != GhostCoordinateSpace.physicalOnWindows) {
      return display.workArea;
    }
    final scale = display.scaleFactor;
    final area = display.workArea;
    return Rect.fromLTWH(
      area.left * scale,
      area.top * scale,
      area.width * scale,
      area.height * scale,
    );
  }

  /// A frame in the adapter's logical space, from the stored space.
  /// window_manager multiplies logical values by whatever
  /// getDevicePixelRatio() returns *right now* and lands exact physical
  /// coordinates — no waiting for metrics to settle.
  Rect _toLogicalSpace(Rect stored) {
    if (_platform != GhostDesktopPlatform.windows ||
        _coordinates != GhostCoordinateSpace.physicalOnWindows) {
      return stored;
    }
    final ratio = _window.getDevicePixelRatio();
    return Rect.fromLTWH(
      stored.left / ratio,
      stored.top / ratio,
      stored.width / ratio,
      stored.height / ratio,
    );
  }

  /// A frame from the adapter's logical space, into the stored space —
  /// the exact inverse of [_toLogicalSpace].
  Rect _toStoredSpace(Rect logical) {
    if (_platform != GhostDesktopPlatform.windows ||
        _coordinates != GhostCoordinateSpace.physicalOnWindows) {
      return logical;
    }
    final ratio = _window.getDevicePixelRatio();
    return Rect.fromLTWH(
      logical.left * ratio,
      logical.top * ratio,
      logical.width * ratio,
      logical.height * ratio,
    );
  }

  bool _isCurrentCalibration(int revision) {
    return !_closing && revision == _calibrationRevision;
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must not create an unhandled callback failure.
    }
  }

  bool _isFinitePositive(Size size) {
    return size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0;
  }
}

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show
        AppLock,
        AppLockAvailability,
        AppLockException,
        AppLockLifecycle,
        AppLockMode,
        DeviceAuthenticator,
        appLockBackgroundTimeout;

/// Whether this device can lock the app (SAF-20).
enum AppLockSupport {
  /// The platform has no system prompt the lock can call (Linux).
  unsupported,

  /// The platform has one, but the device has no passcode, PIN or
  /// biometrics set up, or could not say.
  unavailable,

  available,
}

/// How turning the app lock on or off ended. Every outcome but [changed]
/// leaves the lock as it was.
enum AppLockChange {
  changed,

  /// The device authentication the change needs failed or was cancelled.
  notAuthenticated,

  /// The device has no authentication to ask for.
  unavailable,

  /// The authentication passed but `settings.json` could not be written,
  /// so the old setting stays in force.
  notSaved,
}

/// How an unlock attempt ended.
enum AppLockUnlock { unlocked, failed, unavailable }

/// What Settings reads and changes of the app lock, apart from where it
/// runs: [AppLockController] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class AppLockSettings implements Listenable {
  /// Whether the lock is on.
  bool get enabled;

  /// Whether the app is locked now, behind its lock screen.
  bool get locked;

  AppLockSupport get support;

  /// Turns the lock on or off after a fresh device authentication; a
  /// no-op answering [AppLockChange.changed] when [enabled] is already in
  /// force.
  Future<AppLockChange> setEnabled(bool enabled);
}

/// The app lock (03 §8.2, SAF-20) over the suite's [AppLock]: with the
/// lock on, the app opens behind the lock screen, which asks for device
/// authentication, and it locks again once it has been in the background
/// or hidden for [appLockBackgroundTimeout]. The keystore's reads go
/// through [read], so a locked app hands the engine no credential; links
/// already open keep running, as in Séance.
///
/// [onLocked] runs each time the lock engages after an unlock, for the
/// admin windows that end then (03 §8.2). [save] stores the setting; a
/// change is in force only once it is saved. Without it, as in tests, the
/// setting is held in memory.
final class AppLockController extends ChangeNotifier
    implements AppLockSettings {
  AppLockController({
    required DeviceAuthenticator authenticator,
    required bool supported,
    bool enabled = false,
    this._save,
    this._onLocked,
    Duration Function()? elapsed,
    DateTime Function()? wallClock,
  }) : _supported = supported,
       // An unsupported platform could never unlock, so a setting copied
       // from another device does not lock it.
       _enabled = supported && enabled,
       _lock = AppLock(
         authenticator: authenticator,
         mode: supported && enabled ? AppLockMode.on : AppLockMode.off,
         elapsed: elapsed,
         wallClock: wallClock,
       ) {
    _wasLocked = _lock.requiresAuthentication;
  }

  final AppLock _lock;
  final bool _supported;
  final Future<void> Function(bool enabled)? _save;
  final VoidCallback? _onLocked;
  bool _enabled;
  bool _wasLocked = false;

  /// Notices the lock engaging while the app stays hidden on a desktop,
  /// where timers keep running; a phone's resume notices it instead.
  Timer? _background;

  @override
  bool get enabled => _enabled;

  @override
  AppLockSupport get support {
    if (!_supported) return AppLockSupport.unsupported;
    return _lock.availability == AppLockAvailability.available
        ? AppLockSupport.available
        : AppLockSupport.unavailable;
  }

  /// Whether the lock screen covers the app.
  @override
  bool get locked => _lock.requiresAuthentication;

  /// Asks the device again whether it can authenticate; the switch and
  /// the lock screen read [support].
  Future<void> refreshAvailability() async {
    if (!_supported) return;
    await _lock.refreshAvailability();
    notifyListeners();
  }

  /// Asks for device authentication when locked. Concurrent calls, the
  /// keystore's [read] included, share one prompt.
  Future<AppLockUnlock> unlock() async {
    try {
      await _lock.requireUnlocked();
      return AppLockUnlock.unlocked;
    } on AppLockException {
      return _lock.availability == AppLockAvailability.available
          ? AppLockUnlock.failed
          : AppLockUnlock.unavailable;
    } finally {
      _check();
    }
  }

  /// Runs [operation], a keystore read, once unlocked, and drops its
  /// result if the lock engaged meanwhile; throws [AppLockException] when
  /// the app stays locked.
  Future<T> read<T>(Future<T> Function() operation) => _lock.read(operation);

  void onLifecycle(AppLifecycleState state) {
    _lock.onLifecycle(switch (state) {
      AppLifecycleState.resumed => AppLockLifecycle.foreground,
      AppLifecycleState.inactive => AppLockLifecycle.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => AppLockLifecycle.background,
    });
    _background?.cancel();
    _background = null;
    if (state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive &&
        _enabled) {
      // A moment past the timeout, so the lock has expired when it fires.
      _background = Timer(
        appLockBackgroundTimeout + const Duration(seconds: 1),
        _check,
      );
    }
    _check();
  }

  @override
  Future<AppLockChange> setEnabled(bool enabled) async {
    if (enabled == _enabled) return AppLockChange.changed;
    if (!_supported) return AppLockChange.unavailable;

    var saved = true;
    try {
      await _lock.changeMode(
        enabled ? AppLockMode.on : AppLockMode.off,
        persist: () async {
          try {
            await _save?.call(enabled);
          } on Object {
            saved = false;
            rethrow;
          }
        },
      );
    } on AppLockException {
      notifyListeners();
      return _lock.availability == AppLockAvailability.available
          ? AppLockChange.notAuthenticated
          : AppLockChange.unavailable;
    } on Object {
      if (saved) rethrow;
      return AppLockChange.notSaved;
    }
    _enabled = enabled;
    // Turning the lock on just authenticated, so the app stays open.
    _wasLocked = _lock.requiresAuthentication;
    notifyListeners();
    return AppLockChange.changed;
  }

  /// Notifies when the lock engaged or released, and runs [_onLocked] when
  /// it engaged.
  void _check() {
    final locked = _lock.requiresAuthentication;
    if (locked == _wasLocked) return;
    _wasLocked = locked;
    if (locked) _onLocked?.call();
    notifyListeners();
  }

  @override
  void dispose() {
    _background?.cancel();
    super.dispose();
  }
}

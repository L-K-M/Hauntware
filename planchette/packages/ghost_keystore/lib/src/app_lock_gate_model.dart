import 'package:flutter/widgets.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostAppLockGateModel, GhostAppLockUnlock;

import 'app_lock_controller.dart';

/// An app's [AppLockController] as ghost_ui's lock gate seam, so every
/// app hands `GhostAppLockGate` the same adapter instead of its own copy.
/// ghost_ui keeps no keystore import, which is why the mapping lives here.
final class AppLockGateModel implements GhostAppLockGateModel {
  const AppLockGateModel(this._lock);

  final AppLockController _lock;

  @override
  bool get locked => _lock.locked;

  @override
  Future<void> refreshAvailability() => _lock.refreshAvailability();

  @override
  Future<GhostAppLockUnlock> unlock() async => switch (await _lock.unlock()) {
    AppLockUnlock.unlocked => GhostAppLockUnlock.unlocked,
    AppLockUnlock.failed => GhostAppLockUnlock.failed,
    AppLockUnlock.unavailable => GhostAppLockUnlock.unavailable,
  };

  @override
  void onLifecycle(AppLifecycleState state) => _lock.onLifecycle(state);

  @override
  void addListener(VoidCallback listener) => _lock.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _lock.removeListener(listener);

  /// The gate compares models to notice a new lock; a new wrapper over the
  /// same controller is the same lock, so a rebuild does not restart the
  /// locked spell.
  @override
  bool operator ==(Object other) =>
      other is AppLockGateModel && other._lock == _lock;

  @override
  int get hashCode => _lock.hashCode;
}

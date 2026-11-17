/// The device-local app lock alone (03 §3.5 F5f): `AppLock`, its modes
/// and the `DeviceAuthenticator` seam (implemented over the OS plugin by
/// `device_authenticator.dart`, and by fakes in tests), plus the `AppLockController` each app host
/// drives from its settings and lifecycle and the Settings switch over it
/// (`GhostAppLockSection`), and `AppLockGateModel`, the controller as
/// ghost_ui's lock gate seam. The lock core is pure Dart; the controller,
/// the switch and the gate model are the Flutter pieces.
///
/// A library of its own so an app whose keystore classes predate
/// `MasterKeyManager` here, as Séance's do, can import the lock without
/// their names clashing; the package barrel exports it too.
library;

export 'src/app_lock.dart';
export 'src/app_lock_controller.dart';
export 'src/app_lock_gate_model.dart';
export 'src/app_lock_section.dart';

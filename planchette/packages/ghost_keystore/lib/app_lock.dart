/// The device-local app lock alone (03 §3.5 F5f): `AppLock`, its modes
/// and the `DeviceAuthenticator` seam each app implements over its own
/// OS authentication plugin. Pure Dart.
///
/// A library of its own so an app whose keystore classes predate
/// `MasterKeyManager` here, as Séance's do, can import the lock without
/// their names clashing; the package barrel exports it too.
library;

export 'src/app_lock.dart';

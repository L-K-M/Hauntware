/// The suite's one `DeviceAuthenticator` over the OS authentication
/// plugin, `local_auth`: Séance, Poltergeist, Klabautermann and
/// Planchette construct it with their own prompt line. A library of its
/// own, outside the barrels, so only the code that wires the lock names
/// the plugin; every app that uses this package already ships it
/// (docs/design/catalog-library.md section 9).
library;

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'src/app_lock.dart';

/// Whether [platform] has the device authentication the app lock asks
/// for: `local_auth` answers on Android, iOS, macOS and Windows; Linux
/// has no system prompt it can call.
bool appLockSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  TargetPlatform.linux || TargetPlatform.fuchsia => false,
};

/// The system's own prompt, biometrics with the device passcode or PIN
/// as its fallback, over `local_auth`. [reason] is the line the prompt
/// shows, supplied by the app and read when the prompt opens, so a
/// localized app follows the current locale.
///
/// Never biometrics alone, and never a prompt that survives the app going
/// to the background: `AppLock` decides what a backgrounded prompt means.
/// The [AppLockException] messages are product-neutral English; an app
/// that shows them (Séance does) shows them as they are.
final class LocalDeviceAuthenticator implements DeviceAuthenticator {
  LocalDeviceAuthenticator({
    required this._reason,
    LocalAuthentication? authentication,
    TargetPlatform? platform,
  }) : _authentication = authentication ?? LocalAuthentication(),
       _platform = platform ?? defaultTargetPlatform;

  final String Function() _reason;
  final LocalAuthentication _authentication;
  final TargetPlatform _platform;

  bool get _supported => !kIsWeb && appLockSupportedOn(_platform);

  @override
  Future<AppLockAvailability> availability() async {
    if (!_supported) return AppLockAvailability.unavailable;

    return await _authentication.isDeviceSupported()
        ? AppLockAvailability.available
        : AppLockAvailability.unavailable;
  }

  @override
  Future<void> authenticate() async {
    if (!_supported) {
      throw const AppLockException(
        'App lock: device authentication is unavailable on this platform.',
      );
    }

    final bool accepted;
    try {
      accepted = await _authentication.authenticate(
        localizedReason: _reason(),
        biometricOnly: false,
        persistAcrossBackgrounding: false,
      );
    } on LocalAuthException catch (error) {
      throw AppLockException(
        'App lock: device authentication failed (${error.code.name}). Retry '
        'to access saved secrets.',
      );
    }
    if (!accepted) {
      throw const AppLockException(
        'App lock: authentication was cancelled or rejected. Retry to access '
        'saved secrets.',
      );
    }
  }
}

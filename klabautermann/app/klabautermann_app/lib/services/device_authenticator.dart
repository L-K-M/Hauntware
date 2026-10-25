import 'package:flutter/foundation.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show AppLockAvailability, AppLockException, DeviceAuthenticator;
import 'package:local_auth/local_auth.dart';

/// Whether [platform] has the device authentication the app lock asks
/// for (SAF-20): `local_auth` answers on Android, iOS, macOS and
/// Windows; Linux has no system prompt it can call.
bool appLockSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  TargetPlatform.linux || TargetPlatform.fuchsia => false,
};

/// The system's own prompt, biometrics with the device passcode or PIN
/// as its fallback, over `local_auth`. [reason] is the localized line the
/// prompt shows, read when it opens so it follows the current locale.
///
/// The [AppLockException]s it throws are never shown: the app lock's
/// screens word failures from [AppLockAvailability] alone.
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

  @override
  Future<AppLockAvailability> availability() async {
    if (kIsWeb || !appLockSupportedOn(_platform)) {
      return AppLockAvailability.unavailable;
    }
    return await _authentication.isDeviceSupported()
        ? AppLockAvailability.available
        : AppLockAvailability.unavailable;
  }

  @override
  Future<void> authenticate() async {
    final bool accepted;
    try {
      accepted = await _authentication.authenticate(
        localizedReason: _reason(),
        biometricOnly: false,
        persistAcrossBackgrounding: false,
      );
    } on LocalAuthException catch (error) {
      throw AppLockException('device authentication failed: ${error.code}');
    }
    if (!accepted) {
      throw const AppLockException('device authentication was rejected');
    }
  }
}

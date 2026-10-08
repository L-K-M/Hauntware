import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'app_lock.dart';

bool appLockSupportedOn(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  TargetPlatform.linux || TargetPlatform.fuchsia => false,
};

/// The OS chooses biometrics or its device passcode/PIN fallback.
class NativeDeviceAuthenticator implements DeviceAuthenticator {
  NativeDeviceAuthenticator({
    LocalAuthentication? authentication,
    TargetPlatform? platform,
  }) : _authentication = authentication ?? LocalAuthentication(),
       _platform = platform ?? defaultTargetPlatform;

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
    try {
      final accepted = await _authentication.authenticate(
        localizedReason: 'Authenticate to access Séance saved secrets.',
        biometricOnly: false,
        persistAcrossBackgrounding: false,
      );
      if (accepted) return;
      throw const AppLockException(
        'App lock: authentication was cancelled or rejected. Retry to access '
        'saved secrets.',
      );
    } on LocalAuthException catch (error) {
      throw AppLockException(
        'App lock: device authentication failed (${error.code.name}). Retry '
        'to access saved secrets.',
      );
    }
  }
}

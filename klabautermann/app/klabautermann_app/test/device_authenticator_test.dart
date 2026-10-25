import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show AppLockAvailability, AppLockException;
import 'package:klabautermann_app/services/device_authenticator.dart';

/// SAF-20: the system prompt behind the app lock.
void main() {
  test('a platform without a system prompt is unavailable and refuses to '
      'ask, as an AppLockException', () async {
    final device = LocalDeviceAuthenticator(
      reason: () => 'unlock',
      platform: TargetPlatform.linux,
    );

    expect(await device.availability(), AppLockAvailability.unavailable);
    await expectLater(device.authenticate(), throwsA(isA<AppLockException>()));
  });
}

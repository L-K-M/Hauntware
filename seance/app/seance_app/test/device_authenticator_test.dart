import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:seance_app/services/app_lock.dart';
import 'package:seance_app/services/device_authenticator.dart';

class _Authentication extends LocalAuthentication {
  bool supported = true;
  bool accepted = true;
  bool? biometricOnly;
  bool? persists;
  Object? failure;
  Object? checkFailure;
  int checks = 0;

  @override
  Future<bool> isDeviceSupported() async {
    checks++;
    if (checkFailure != null) throw checkFailure!;
    return supported;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    this.biometricOnly = biometricOnly;
    persists = persistAcrossBackgrounding;
    if (failure != null) throw failure!;
    return accepted;
  }
}

void main() {
  for (final platform in TargetPlatform.values) {
    test(
      'availability on ${platform.name} requires a supported OS and device',
      () async {
        final plugin = _Authentication();
        final adapter = NativeDeviceAuthenticator(
          authentication: plugin,
          platform: platform,
        );
        final supported = [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        ].contains(platform);
        expect(appLockSupportedOn(platform), supported);
        expect(
          await adapter.availability(),
          supported
              ? AppLockAvailability.available
              : AppLockAvailability.unavailable,
        );
        expect(plugin.checks, supported ? 1 : 0);
        plugin.supported = false;
        expect(await adapter.availability(), AppLockAvailability.unavailable);
      },
    );
  }

  test('native auth allows passcode fallback without sticky retry', () async {
    final plugin = _Authentication();
    await NativeDeviceAuthenticator(authentication: plugin).authenticate();
    expect(plugin.biometricOnly, isFalse);
    expect(plugin.persists, isFalse);
  });

  test('cancel/rejection is an app-lock error', () async {
    final plugin = _Authentication()..accepted = false;
    await expectLater(
      NativeDeviceAuthenticator(authentication: plugin).authenticate(),
      throwsA(isA<AppLockException>()),
    );
  });

  test('native failures cannot be mistaken for a missing key', () async {
    final plugin = _Authentication()
      ..failure = const LocalAuthException(
        code: LocalAuthExceptionCode.temporaryLockout,
      );
    await expectLater(
      NativeDeviceAuthenticator(authentication: plugin).authenticate(),
      throwsA(isA<AppLockException>()),
    );
  });

  test('a missing native plugin makes the option unavailable', () async {
    final plugin = _Authentication()..checkFailure = MissingPluginException();
    final gate = AppLock(
      authenticator: NativeDeviceAuthenticator(authentication: plugin),
      mode: AppLockMode.on,
    );
    await expectLater(
      gate.read(() async => 'secret'),
      throwsA(isA<AppLockException>()),
    );
    expect(gate.availability, AppLockAvailability.unavailable);
    expect(plugin.biometricOnly, isNull);
  });
}

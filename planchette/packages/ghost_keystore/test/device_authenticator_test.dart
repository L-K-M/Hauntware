import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:ghost_keystore/device_authenticator.dart';
import 'package:local_auth/local_auth.dart';

/// The plugin as the test decides it, recording what the adapter asked.
class _Authentication extends LocalAuthentication {
  bool supported = true;
  bool accepted = true;
  String? reason;
  bool? biometricOnly;
  bool? persists;
  Object? failure;
  Object? checkFailure;
  int checks = 0;
  int prompts = 0;

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
    prompts++;
    reason = localizedReason;
    this.biometricOnly = biometricOnly;
    persists = persistAcrossBackgrounding;
    if (failure != null) throw failure!;
    return accepted;
  }
}

const _supportedPlatforms = [
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.windows,
];

void main() {
  LocalDeviceAuthenticator device(
    _Authentication plugin, {
    TargetPlatform platform = TargetPlatform.android,
    String Function()? reason,
  }) => LocalDeviceAuthenticator(
    reason: reason ?? () => 'unlock',
    authentication: plugin,
    platform: platform,
  );

  for (final platform in TargetPlatform.values) {
    test(
      'availability on ${platform.name} requires a supported OS and device',
      () async {
        final plugin = _Authentication();
        final adapter = device(plugin, platform: platform);
        final supported = _supportedPlatforms.contains(platform);

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

  test('a platform without a system prompt is unavailable and refuses to '
      'ask, as an AppLockException', () async {
    for (final platform in [TargetPlatform.linux, TargetPlatform.fuchsia]) {
      final plugin = _Authentication();
      final adapter = device(plugin, platform: platform);

      expect(await adapter.availability(), AppLockAvailability.unavailable);
      await expectLater(
        adapter.authenticate(),
        throwsA(isA<AppLockException>()),
      );
      expect(plugin.prompts, 0, reason: platform.name);
    }
  });

  test('the prompt shows the reason the app supplies, read when it '
      'opens', () async {
    final plugin = _Authentication();
    var line = 'first';
    final adapter = device(plugin, reason: () => line);

    await adapter.authenticate();
    expect(plugin.reason, 'first');

    line = 'second';
    await adapter.authenticate();
    expect(plugin.reason, 'second');
  });

  test('native auth allows passcode fallback without sticky retry', () async {
    final plugin = _Authentication();
    await device(plugin).authenticate();
    expect(plugin.biometricOnly, isFalse);
    expect(plugin.persists, isFalse);
  });

  test('cancel/rejection is an app-lock error', () async {
    final plugin = _Authentication()..accepted = false;
    await expectLater(
      device(plugin).authenticate(),
      throwsA(isA<AppLockException>()),
    );
  });

  test('native failures cannot be mistaken for a missing key', () async {
    final plugin = _Authentication()
      ..failure = const LocalAuthException(
        code: LocalAuthExceptionCode.temporaryLockout,
      );
    await expectLater(
      device(plugin).authenticate(),
      throwsA(
        isA<AppLockException>().having(
          (error) => error.message,
          'message',
          contains('(temporaryLockout)'),
        ),
      ),
    );
  });

  test('a missing native plugin makes the option unavailable', () async {
    final plugin = _Authentication()..checkFailure = MissingPluginException();
    final gate = AppLock(authenticator: device(plugin), mode: AppLockMode.on);
    await expectLater(
      gate.read(() async => 'secret'),
      throwsA(isA<AppLockException>()),
    );
    expect(gate.availability, AppLockAvailability.unavailable);
    expect(plugin.prompts, 0);
  });
}

import 'dart:async';

import 'package:ghost_keystore/ghost_keystore.dart';

/// A device whose authentication the test decides: [available] says
/// whether it has any, [accept] whether the next prompts pass, and
/// [hold] keeps a prompt open until the test completes it.
final class FakeDeviceAuthenticator implements DeviceAuthenticator {
  bool available = true;
  bool accept = true;
  int prompts = 0;

  /// While non-null, a prompt waits for it.
  Completer<void>? hold;

  /// While non-null, a prompt throws it, as a platform channel that fails
  /// some other way than refusing.
  Object? failWith;

  @override
  Future<AppLockAvailability> availability() async => available
      ? AppLockAvailability.available
      : AppLockAvailability.unavailable;

  @override
  Future<void> authenticate() async {
    prompts++;
    await hold?.future;
    if (failWith case final error?) throw error;
    if (!accept) throw const AppLockException('rejected');
  }
}

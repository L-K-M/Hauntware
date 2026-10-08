import 'package:seance_app/services/app_lock.dart';

class TestDeviceAuthenticator implements DeviceAuthenticator {
  AppLockAvailability supported = AppLockAvailability.available;
  int prompts = 0;
  Future<void> Function()? onAuthenticate;
  Future<AppLockAvailability> Function()? onAvailability;

  @override
  Future<AppLockAvailability> availability() async =>
      await onAvailability?.call() ?? supported;

  @override
  Future<void> authenticate() async {
    prompts++;
    await onAuthenticate?.call();
  }

  void reject() {
    onAuthenticate = () async => throw const AppLockException('Auth cancelled');
  }
}

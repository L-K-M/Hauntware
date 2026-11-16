import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:ghost_keystore/testing.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostAppLockUnlock;

/// The controller as ghost_ui's lock gate seam, shared by every app.
void main() {
  late FakeDeviceAuthenticator device;

  setUp(() => device = FakeDeviceAuthenticator());

  AppLockController controller() =>
      AppLockController(authenticator: device, supported: true, enabled: true);

  test('the model reports the lock and maps each unlock outcome', () async {
    final lock = controller();
    addTearDown(lock.dispose);
    final model = AppLockGateModel(lock);

    expect(model.locked, isTrue);
    await model.refreshAvailability();
    expect(model.locked, isTrue);

    device.accept = false;
    expect(await model.unlock(), GhostAppLockUnlock.failed);

    device.available = false;
    expect(await model.unlock(), GhostAppLockUnlock.unavailable);

    device.available = true;
    device.accept = true;
    expect(await model.unlock(), GhostAppLockUnlock.unlocked);
    expect(model.locked, isFalse);
  });

  test('wrappers over one controller are the same model', () {
    final lock = controller();
    final other = controller();
    addTearDown(lock.dispose);
    addTearDown(other.dispose);

    expect(AppLockGateModel(lock), AppLockGateModel(lock));
    expect(AppLockGateModel(lock).hashCode, AppLockGateModel(lock).hashCode);
    expect(AppLockGateModel(lock), isNot(AppLockGateModel(other)));
  });

  test('listeners reach the controller until removed', () async {
    final lock = controller();
    addTearDown(lock.dispose);
    final model = AppLockGateModel(lock);
    var notified = 0;
    void listener() => notified++;
    model.addListener(listener);

    await model.unlock();
    expect(notified, greaterThan(0));

    model.removeListener(listener);
    final before = notified;
    await lock.refreshAvailability();
    expect(notified, before);
  });
}

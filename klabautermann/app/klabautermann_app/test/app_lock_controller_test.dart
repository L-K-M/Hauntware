import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart'
    show AppLockException, appLockBackgroundTimeout;
import 'package:klabautermann_app/controllers/app_lock_controller.dart';

import 'support/device_authenticator.dart';

/// SAF-20: the app lock over ghost_keystore's AppLock.
void main() {
  late FakeDeviceAuthenticator device;
  late Duration elapsed;
  late DateTime wall;
  late List<bool> saved;
  late int locks;

  setUp(() {
    device = FakeDeviceAuthenticator();
    elapsed = Duration.zero;
    wall = DateTime.utc(2026, 10, 25, 12);
    saved = [];
    locks = 0;
  });

  AppLockController controller({
    bool enabled = true,
    bool supported = true,
    Future<void> Function(bool enabled)? save,
  }) => AppLockController(
    authenticator: device,
    supported: supported,
    enabled: enabled,
    save: save ?? (enabled) async => saved.add(enabled),
    onLocked: () => locks++,
    elapsed: () => elapsed,
    wallClock: () => wall,
  );

  void away(Duration duration) {
    elapsed += duration;
    wall = wall.add(duration);
  }

  test('off, the app never locks and the keystore reads at once', () async {
    final lock = controller(enabled: false);
    expect(lock.locked, isFalse);
    expect(await lock.read(() async => 'key'), 'key');
    expect(device.prompts, 0);
  });

  test('on, the app opens locked and unlocks after device '
      'authentication', () async {
    final lock = controller();
    await lock.refreshAvailability();
    expect(lock.locked, isTrue);
    expect(lock.support, AppLockSupport.available);

    expect(await lock.unlock(), AppLockUnlock.unlocked);
    expect(lock.locked, isFalse);
    expect(device.prompts, 1);
    expect(await lock.read(() async => 'key'), 'key');
    expect(device.prompts, 1);
  });

  test('a keystore read while locked asks once, sharing the lock '
      'screen prompt', () async {
    final lock = controller();
    device.hold = Completer<void>();

    final unlock = lock.unlock();
    final read = lock.read(() async => 'key');
    await pumpEventQueue();
    expect(device.prompts, 1);

    device.hold!.complete();
    expect(await unlock, AppLockUnlock.unlocked);
    expect(await read, 'key');
    expect(device.prompts, 1);
  });

  test('a rejected prompt keeps the app locked and its reads refused; a '
      'device with no authentication says so', () async {
    final lock = controller();
    device.accept = false;

    expect(await lock.unlock(), AppLockUnlock.failed);
    expect(lock.locked, isTrue);
    await expectLater(
      lock.read(() async => 'key'),
      throwsA(isA<AppLockException>()),
    );

    device.available = false;
    expect(await lock.unlock(), AppLockUnlock.unavailable);
    expect(lock.support, AppLockSupport.unavailable);
  });

  test('it locks again after the background timeout, not before, and '
      'ends admin mode when it does', () async {
    final lock = controller();
    await lock.unlock();

    lock.onLifecycle(AppLifecycleState.hidden);
    away(appLockBackgroundTimeout - const Duration(seconds: 1));
    lock.onLifecycle(AppLifecycleState.resumed);
    expect(lock.locked, isFalse);
    expect(locks, 0);

    lock.onLifecycle(AppLifecycleState.paused);
    away(appLockBackgroundTimeout);
    lock.onLifecycle(AppLifecycleState.resumed);
    expect(lock.locked, isTrue);
    expect(locks, 1);
  });

  testWidgets('a desktop window hidden past the timeout locks while still '
      'hidden', (tester) async {
    final lock = controller();
    await lock.unlock();
    var notified = 0;
    lock.addListener(() => notified++);

    lock.onLifecycle(AppLifecycleState.hidden);
    away(appLockBackgroundTimeout + const Duration(seconds: 1));
    await tester.pump(appLockBackgroundTimeout + const Duration(seconds: 1));

    expect(lock.locked, isTrue);
    expect(locks, 1);
    expect(notified, greaterThan(0));
    lock.dispose();
  });

  test('turning the lock on or off asks first, saves, and only then takes '
      'effect', () async {
    final lock = controller(enabled: false);
    await lock.refreshAvailability();

    device.accept = false;
    expect(await lock.setEnabled(true), AppLockChange.notAuthenticated);
    expect(lock.enabled, isFalse);
    expect(saved, isEmpty);

    device.accept = true;
    expect(await lock.setEnabled(true), AppLockChange.changed);
    expect(lock.enabled, isTrue);
    expect(saved, [true]);
    // The change itself authenticated, so the app stays open.
    expect(lock.locked, isFalse);

    expect(await lock.setEnabled(false), AppLockChange.changed);
    expect(saved, [true, false]);
    expect(device.prompts, 3);
  });

  test('a change that could not be saved keeps the old setting in '
      'force', () async {
    final lock = controller(
      enabled: false,
      save: (_) async => throw const FileSystemExceptionLike(),
    );

    expect(await lock.setEnabled(true), AppLockChange.notSaved);
    expect(lock.enabled, isFalse);
    expect(lock.locked, isFalse);
  });

  test('a platform with no system prompt never locks, whatever the stored '
      'setting', () async {
    final lock = controller(supported: false);
    await lock.refreshAvailability();

    expect(lock.locked, isFalse);
    expect(lock.enabled, isFalse);
    expect(lock.support, AppLockSupport.unsupported);
    expect(await lock.setEnabled(true), AppLockChange.unavailable);
    expect(device.prompts, 0);
  });
}

/// A failed write, as `settings.json`'s would throw.
final class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike();
}

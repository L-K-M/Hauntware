import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_lock.dart';
import 'package:seance_app/services/app_settings.dart';

import 'support/device_authenticator.dart';

void main() {
  late TestDeviceAuthenticator device;
  late Duration elapsed;
  late DateTime wallTime;

  AppLock lock([AppLockMode mode = AppLockMode.on]) => AppLock(
    authenticator: device,
    mode: mode,
    elapsed: () => elapsed,
    wallClock: () => wallTime,
  );

  setUp(() {
    device = TestDeviceAuthenticator();
    elapsed = Duration.zero;
    wallTime = DateTime.utc(2026);
  });

  test('off and stored defaults preserve reads without device auth', () async {
    expect(AppSettings().appLock, AppLockMode.off);
    expect(AppSettings.fromJson({}).appLock, AppLockMode.off);
    final gate = lock(AppLockMode.off);
    device.reject();
    expect(await gate.read(() async => 'credential'), 'credential');
    expect(device.prompts, 0);
  });

  test('on persists locally and each launch begins locked', () async {
    final settings = AppSettings(appLock: AppLockMode.on);
    expect(AppSettings.fromJson(settings.toJson()).appLock, AppLockMode.on);
    await lock().read(() async => 'credential');
    await lock().read(() async => 'credential');
    expect(device.prompts, 2);
  });

  test(
    'first read authenticates and later foreground reads reuse it',
    () async {
      final gate = lock();
      expect(gate.requiresAuthentication, isTrue);
      expect(await gate.read(() async => 'credential'), 'credential');
      elapsed = const Duration(days: 1);
      expect(await gate.read(() async => 'credential'), 'credential');
      expect(device.prompts, 1);
    },
  );

  for (final away in [
    appLockBackgroundTimeout - const Duration(microseconds: 1),
    appLockBackgroundTimeout,
    appLockBackgroundTimeout + const Duration(microseconds: 1),
  ]) {
    test('foreground after $away applies the inclusive timeout', () async {
      final gate = lock();
      await gate.requireUnlocked();
      gate.onLifecycle(AppLockLifecycle.background);
      elapsed = away;
      gate.onLifecycle(AppLockLifecycle.foreground);
      await gate.read(() async => 'credential');
      expect(device.prompts, away < appLockBackgroundTimeout ? 1 : 2);
    });
  }

  test('inactive never starts or resets a background deadline', () async {
    final gate = lock();
    await gate.requireUnlocked();
    gate.onLifecycle(AppLockLifecycle.inactive);
    elapsed = appLockBackgroundTimeout;
    expect(gate.requiresAuthentication, isFalse);
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed += const Duration(minutes: 4);
    gate.onLifecycle(AppLockLifecycle.inactive);
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed += const Duration(minutes: 1);
    gate.onLifecycle(AppLockLifecycle.foreground);
    expect(gate.requiresAuthentication, isTrue);
  });

  test('background sleep counts while the monotonic clock pauses', () async {
    final gate = lock();
    await gate.requireUnlocked();
    gate.onLifecycle(AppLockLifecycle.background);
    wallTime = wallTime.add(appLockBackgroundTimeout);
    gate.onLifecycle(AppLockLifecycle.foreground);
    await gate.requireUnlocked();
    expect(device.prompts, 2);
  });

  test('a backwards wall clock cannot extend an elapsed timeout', () async {
    final gate = lock();
    await gate.requireUnlocked();
    gate.onLifecycle(AppLockLifecycle.background);
    wallTime = wallTime.subtract(const Duration(days: 1));
    elapsed = appLockBackgroundTimeout;
    gate.onLifecycle(AppLockLifecycle.foreground);
    await gate.requireUnlocked();
    expect(device.prompts, 2);
  });

  test('concurrent reads share one prompt', () async {
    final answer = Completer<void>();
    device.onAuthenticate = () => answer.future;
    final gate = lock();
    var reads = 0;
    final futures = List.generate(3, (_) => gate.read(() async => ++reads));
    await Future<void>.delayed(Duration.zero);
    expect(device.prompts, 1);
    expect(reads, 0);
    answer.complete();
    expect(await Future.wait(futures), [1, 2, 3]);
  });

  test(
    'shared cancellation releases nothing and a future read retries',
    () async {
      final answer = Completer<void>();
      device.onAuthenticate = () => answer.future;
      final gate = lock();
      var reads = 0;
      final first = gate.read(() async => ++reads);
      final second = gate.read(() async => ++reads);
      final failures = [
        expectLater(first, throwsA(isA<AppLockException>())),
        expectLater(second, throwsA(isA<AppLockException>())),
      ];
      await Future<void>.delayed(Duration.zero);
      answer.completeError(const AppLockException('Cancelled'));
      await Future.wait(failures);
      expect(reads, 0);
      device.onAuthenticate = null;
      expect(await gate.read(() async => ++reads), 1);
      expect(device.prompts, 2);
    },
  );

  test('unexpected auth failure is explicit and retryable', () async {
    device.onAuthenticate = () async => throw StateError('Device failure');
    final gate = lock();
    await expectLater(
      gate.read(() async => 'secret'),
      throwsA(isA<AppLockException>()),
    );
    expect(gate.requiresAuthentication, isTrue);
    device.onAuthenticate = null;
    expect(await gate.read(() async => 'secret'), 'secret');
  });

  test('unsupported existing lock fails closed', () async {
    device.supported = AppLockAvailability.unavailable;
    final gate = lock();
    var reads = 0;
    await expectLater(
      gate.read(() async => ++reads),
      throwsA(isA<AppLockException>()),
    );
    expect(reads, 0);
    expect(device.prompts, 0);
  });

  test('a locked background read refuses to start a prompt', () async {
    final gate = lock();
    gate.onLifecycle(AppLockLifecycle.background);
    await expectLater(
      gate.read(() async => 'secret'),
      throwsA(isA<AppLockException>()),
    );
    expect(device.prompts, 0);
    gate.onLifecycle(AppLockLifecycle.foreground);
    expect(await gate.read(() async => 'secret'), 'secret');
  });

  test('auth completion after a background timeout is stale', () async {
    final answer = Completer<void>();
    device.onAuthenticate = () => answer.future;
    final gate = lock();
    final read = gate.read(() async => 'secret');
    final failure = expectLater(read, throwsA(isA<AppLockException>()));
    await Future<void>.delayed(Duration.zero);
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed = appLockBackgroundTimeout;
    gate.onLifecycle(AppLockLifecycle.foreground);
    answer.complete();
    await failure;
    expect(gate.requiresAuthentication, isTrue);
    device.onAuthenticate = null;
    expect(await gate.read(() async => 'secret'), 'secret');
  });

  test(
    'auth success while backgrounded releases nothing and can retry',
    () async {
      final answer = Completer<void>();
      device.onAuthenticate = () => answer.future;
      final gate = lock();
      var reads = 0;
      final failure = expectLater(
        gate.read(() async => ++reads),
        throwsA(isA<AppLockException>()),
      );
      await Future<void>.delayed(Duration.zero);
      gate.onLifecycle(AppLockLifecycle.background);
      answer.complete();
      await failure;
      expect(reads, 0);
      expect(gate.requiresAuthentication, isTrue);

      gate.onLifecycle(AppLockLifecycle.foreground);
      device.onAuthenticate = null;
      expect(await gate.read(() async => ++reads), 1);
      expect(device.prompts, 2);
    },
  );

  for (final resumed in [false, true]) {
    test('a delayed availability check cannot prompt after leaving, '
        'resumed: $resumed', () async {
      final available = Completer<AppLockAvailability>();
      device.onAvailability = () => available.future;
      final gate = lock();
      final failure = expectLater(
        gate.read(() async => 'secret'),
        throwsA(isA<AppLockException>()),
      );
      await Future<void>.delayed(Duration.zero);
      gate.onLifecycle(AppLockLifecycle.background);
      if (resumed) {
        elapsed = appLockBackgroundTimeout;
        gate.onLifecycle(AppLockLifecycle.foreground);
      }
      available.complete(AppLockAvailability.available);
      await failure;
      expect(device.prompts, 0);
    });
  }

  test('auth UI foreground events cannot erase a pending absence', () async {
    final answer = Completer<void>();
    device.onAuthenticate = () => answer.future;
    final gate = lock();
    final failure = expectLater(
      gate.read(() async => 'secret'),
      throwsA(isA<AppLockException>()),
    );
    await Future<void>.delayed(Duration.zero);
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed = const Duration(minutes: 4);
    gate.onLifecycle(AppLockLifecycle.foreground);
    gate.onLifecycle(AppLockLifecycle.inactive);
    elapsed = appLockBackgroundTimeout;
    answer.complete();
    await failure;
    expect(gate.requiresAuthentication, isTrue);
  });

  test('an in-flight storage read cannot release after relocking', () async {
    final gate = lock();
    await gate.requireUnlocked();
    final storage = Completer<String>();
    final failure = expectLater(
      gate.read(() => storage.future),
      throwsA(isA<AppLockException>()),
    );
    await Future<void>.delayed(Duration.zero);
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed = appLockBackgroundTimeout;
    gate.onLifecycle(AppLockLifecycle.foreground);
    await gate.requireUnlocked();
    storage.complete('secret');
    await failure;
  });

  test(
    'a timeout between auth and read admission prevents storage access',
    () async {
      final gate = lock();
      var reads = 0;
      final admitted = gate.requireUnlocked();
      admitted.then((_) {
        gate.onLifecycle(AppLockLifecycle.background);
        elapsed = appLockBackgroundTimeout;
        gate.onLifecycle(AppLockLifecycle.foreground);
      });
      await expectLater(
        gate.read(() async => ++reads),
        throwsA(isA<AppLockException>()),
      );
      expect(reads, 0);
    },
  );

  for (final mode in AppLockMode.values) {
    test(
      'rejected change to ${mode.name} does not persist or change policy',
      () async {
        final gate = lock(
          mode == AppLockMode.on ? AppLockMode.off : AppLockMode.on,
        );
        device.reject();
        var writes = 0;
        await expectLater(
          gate.changeMode(
            mode,
            persist: () async {
              writes++;
            },
          ),
          throwsA(isA<AppLockException>()),
        );
        expect(writes, 0);
        expect(gate.requiresAuthentication, mode == AppLockMode.off);
      },
    );
  }

  test(
    'enable and disable each authenticate despite a previous unlock',
    () async {
      final gate = lock(AppLockMode.off);
      await gate.changeMode(AppLockMode.on, persist: () async {});
      await gate.read(() async => 'secret');
      await gate.changeMode(AppLockMode.off, persist: () async {});
      await gate.read(() async => 'secret');
      expect(device.prompts, 2);
    },
  );

  test('a failed disable write keeps the gate on', () async {
    final gate = lock();
    await expectLater(
      gate.changeMode(
        AppLockMode.off,
        persist: () async {
          throw StateError('Disk full');
        },
      ),
      throwsStateError,
    );
    gate.onLifecycle(AppLockLifecycle.background);
    elapsed = appLockBackgroundTimeout;
    gate.onLifecycle(AppLockLifecycle.foreground);
    expect(gate.requiresAuthentication, isTrue);
  });

  test('expired auth cannot admit a setting write', () async {
    final gate = lock();
    var writes = 0;
    gate.requireUnlocked().then((_) {
      gate.onLifecycle(AppLockLifecycle.background);
      elapsed = appLockBackgroundTimeout;
      gate.onLifecycle(AppLockLifecycle.foreground);
    });
    await expectLater(
      gate.changeMode(
        AppLockMode.off,
        persist: () async {
          writes++;
        },
      ),
      throwsA(isA<AppLockException>()),
    );
    expect(writes, 0);
  });
}

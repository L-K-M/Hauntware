import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:poltergeist_app/services/dynamic_secret_vault.dart';
import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _keyA = List<int>.generate(32, (i) => i);
final _keyB = List<int>.generate(32, (i) => 255 - i);

Secret _secret(String id) => Secret(
      id: id,
      kind: SecretKind.password,
      value: 'value-$id',
      updatedAt: 1,
    );

final class _Authenticator implements DeviceAuthenticator {
  @override
  Future<AppLockAvailability> availability() async =>
      AppLockAvailability.available;

  @override
  Future<void> authenticate() async {}
}

final class _DelayedStore extends InMemoryVaultStore {
  Completer<void>? gate;
  final started = Completer<void>();

  @override
  Future<Uint8List?> getSecretBlob(String id) async {
    if (gate case final pending?) {
      if (!started.isCompleted) started.complete();
      await pending.future;
    }
    return super.getSecretBlob(id);
  }
}

void main() {
  for (final operation in ['getSecret', 'readableSecret']) {
    test('$operation refuses a result after its read authorization expires', () async {
      var elapsed = Duration.zero;
      final lock = AppLock(
        authenticator: _Authenticator(),
        mode: AppLockMode.on,
        elapsed: () => elapsed,
        wallClock: () => DateTime(2026).add(elapsed),
      );
      await lock.requireUnlocked();
      final store = _DelayedStore();
      final source = SecretVault(store, _keyA);
      await source.putSecret(_secret('s1'));
      store.gate = Completer<void>();
      final vault = DynamicSecretVault(
        store,
        () => lock.read(() async => source),
        readGuard: lock.read,
      );
      final pending = operation == 'getSecret'
          ? vault.getSecret('s1')
          : vault.readableSecret('s1');
      await store.started.future;
      lock.onLifecycle(AppLockLifecycle.background);
      elapsed = appLockBackgroundTimeout + const Duration(seconds: 1);
      expect(lock.requiresAuthentication, isTrue);
      final refused = expectLater(pending, throwsA(isA<AppLockException>()));
      store.gate!.complete();
      await refused;
    });
  }

  test('every call lands on the key the provider reports now', () async {
    final store = InMemoryVaultStore();
    var key = _keyA;
    final vault = DynamicSecretVault(
      store,
      () async => SecretVault(store, key),
    );

    await vault.putSecret(_secret('s1'));
    expect((await vault.getSecret('s1'))!.value, 'value-s1');

    // The re-key swaps the keystore entry: the old blob no longer opens,
    // and a new write seals under the new key.
    key = _keyB;
    expect(await vault.readableSecret('s1'), isNull);
    await vault.putSecret(_secret('s2'));
    expect((await SecretVault(store, _keyB).getSecret('s2'))!.value,
        'value-s2');
    expect(await SecretVault(store, _keyA).readableSecret('s2'), isNull);
  });

  test('no key reads as the locked vault and reports nothing', () async {
    final reports = <Object>[];
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => null,
      onError: (error, _) => reports.add(error),
    );

    await expectLater(
      vault.getSecret('s1'),
      throwsA(isA<VaultLockedException>()),
    );
    // Never "unreadable reads as absent": a caller that took a silent null
    // would read a locked vault as an empty one and overwrite the entries
    // it cannot currently see.
    await expectLater(
      vault.readableSecret('s1'),
      throwsA(isA<VaultLockedException>()),
    );
    await expectLater(
      vault.putSecret(_secret('s1')),
      throwsA(isA<VaultLockedException>()),
    );
    await expectLater(
      vault.putSecrets([_secret('s1')]),
      throwsA(isA<VaultLockedException>()),
    );
    // Unlike the retired LockedSecretVault, the production locked shape
    // refuses deletes too.
    await expectLater(
      vault.deleteSecret('s1'),
      throwsA(isA<VaultLockedException>()),
    );
    expect(reports, isEmpty);
  });

  test('read guards do not change the existing mutation policy', () async {
    final store = InMemoryVaultStore();
    final source = SecretVault(store, _keyA);
    Future<T> refuse<T>(Future<T> Function() _) async =>
        throw const AppLockException('Authentication refused.');
    final vault = DynamicSecretVault(
      store,
      () async => source,
      readGuard: refuse,
    );
    await vault.putSecret(_secret('s1'));
    await expectLater(vault.getSecret('s1'), throwsA(isA<AppLockException>()));
    await vault.deleteSecret('s1');
    expect(await source.getSecret('s1'), isNull);
  });

  test('auth refusal keeps its type without reporting a keystore fault', () async {
    final reports = <Object>[];
    const failure = AppLockException('Authentication refused.');
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => throw failure,
      onError: (error, _) => reports.add(error),
    );
    await expectLater(vault.getSecret('s1'), throwsA(same(failure)));
    expect(reports, isEmpty);
  });

  test('a failing keystore reports, then fails the call', () async {
    final reports = <Object>[];
    final failure = StateError('keychain unavailable');
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => throw failure,
      onError: (error, _) => reports.add(error),
    );

    await expectLater(vault.putSecret(_secret('s1')), throwsA(same(failure)));
    expect(reports, [same(failure)]);
  });

  test('a throwing reporter never masks the keystore fault', () async {
    final failure = StateError('keychain unavailable');
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => throw failure,
      onError: (_, _) => throw StateError('reporter down'),
    );

    await expectLater(vault.getSecret('s1'), throwsA(same(failure)));
  });
}

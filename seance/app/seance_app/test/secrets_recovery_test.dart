import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/secrets_recovery.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// One device's OS keystore: keeps what it is given, or is locked.
class _Keystore extends FlutterSecureStorage {
  final Map<String, String> _map = {};
  bool locked = false;

  void _check() {
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _check();
    return _map[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _check();
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

/// Sets up a recovery code on [services], as the confirmed dialog does.
Future<String> _setUpRecovery(AppServices services) async {
  final code = services.newRecoveryCode();
  await services.saveRecoveryCode(code);
  return code;
}

Secret _secret(String id, [String? value]) =>
    Secret(id: id, kind: SecretKind.password, value: value ?? 'value-$id');

/// CRED-05 end to end over the real stores: a code set up on one device
/// opens its export on another device with another vault key.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final directories = <Directory>[];
  final opened = <AppServices>[];

  tearDown(() async {
    for (final services in opened) {
      await services.probe.dispose();
    }
    opened.clear();
    messenger.setMockMethodCallHandler(_pathChannel, null);
    for (final directory in directories) {
      await directory.delete(recursive: true);
    }
    directories.clear();
  });

  Future<Directory> newDirectory() async {
    final directory = await Directory.systemTemp.createTemp('seance-recovery-');
    directories.add(directory);
    return directory;
  }

  /// A device: its own support directory and keystore.
  Future<AppServices> device(Directory directory, _Keystore keystore) async {
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory.path,
    );
    final services = await AppServices.initialize(
      masterKeyManager: MasterKeyManager(keystore),
    );
    opened.add(services);
    return services;
  }

  Future<AppServices> freshDevice() async =>
      device(await newDirectory(), _Keystore());

  /// Device A with two credentials, a recovery code, and its export.
  Future<(AppServices, String, Uint8List)> exported() async {
    final a = await freshDevice();
    await a.vault.putSecrets([_secret('pw-web'), _secret('pw-db')]);
    final code = await _setUpRecovery(a);
    return (a, code, await a.exportSecrets());
  }

  test('an export opens on another device with another key', () async {
    final (a, code, export) = await exported();
    final b = await freshDevice();
    expect(b.vaultKey, isNot(a.vaultKey));

    final summary = await b.restoreSecrets(
      export,
      code,
      policy: RestoreConflictPolicy.keepExisting,
    );

    expect(summary.added, 2);
    expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
    expect((await b.vault.getSecret('pw-db'))!.value, 'value-pw-db');
    // Restoring brings credentials, not the other device's recovery.
    expect(await b.recoveryConfigured(), isFalse);
  });

  test('the code survives a re-key of the vault', () async {
    final a = await freshDevice();
    await a.vault.putSecrets([_secret('pw-web')]);
    final code = await _setUpRecovery(a);

    // Sync enrolment re-keys the vault to the account's key.
    await a.rekeyVaultForTesting(Uint8List.fromList(List.filled(32, 7)));
    final export = await a.exportSecrets();

    final b = await freshDevice();
    final summary = await b.restoreSecrets(
      export,
      code,
      policy: RestoreConflictPolicy.keepExisting,
    );
    expect(summary.added, 1);
    expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
  });

  test('a credential already here is kept or replaced as asked', () async {
    final (_, code, export) = await exported();
    final b = await freshDevice();
    await b.vault.putSecrets([_secret('pw-web', 'mine')]);

    final kept = await b.restoreSecrets(
      export,
      code,
      policy: RestoreConflictPolicy.keepExisting,
    );
    expect((kept.added, kept.kept, kept.replaced), (1, 1, 0));
    expect((await b.vault.getSecret('pw-web'))!.value, 'mine');

    final replaced = await b.restoreSecrets(
      export,
      code,
      policy: RestoreConflictPolicy.replaceExisting,
    );
    expect((replaced.added, replaced.kept, replaced.replaced), (0, 0, 2));
    expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
  });

  test(
    'a credential here that will not open is replaced, even when keeping',
    () async {
      final (_, code, export) = await exported();
      final b = await freshDevice();
      // An orphan sealed under a key nobody holds.
      await b.vault.store.putSecretBlob(
        'pw-web',
        await VaultCrypto.sealJson(
          Uint8List(32),
          _secret('pw-web', 'lost').toJson(),
        ),
      );

      final summary = await b.restoreSecrets(
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect(summary.added, 2);
      expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
    },
  );

  test('a wrong code or an altered file writes nothing', () async {
    final (a, code, export) = await exported();
    final directory = await newDirectory();
    final b = await device(directory, _Keystore());
    await b.vault.putSecrets([_secret('mine')]);
    final vaultFile = File('${directory.path}/vault.json');
    final before = await vaultFile.readAsString();

    await expectLater(
      b.restoreSecrets(
        export,
        RecoveryKey.encode(Uint8List(32)),
        policy: RestoreConflictPolicy.replaceExisting,
      ),
      throwsA(
        isA<SecretsExportException>().having(
          (e) => e.failure,
          'failure',
          SecretsExportFailure.wrongCode,
        ),
      ),
    );
    final altered = Uint8List.fromList(export)..[export.length ~/ 2] ^= 0x01;
    await expectLater(
      b.restoreSecrets(
        altered,
        code,
        policy: RestoreConflictPolicy.replaceExisting,
      ),
      throwsA(isA<SecretsExportException>()),
    );
    expect(await vaultFile.readAsString(), before);
    expect(a.vaultKey, isNotNull);
  });

  test('export needs a code, and a locked vault does nothing', () async {
    final a = await freshDevice();
    await expectLater(
      a.exportSecrets(),
      throwsA(isA<RecoveryNotSetUpException>()),
    );

    final keystore = _Keystore()..locked = true;
    final locked = await device(await newDirectory(), keystore);
    expect(locked.vaultKey, isNull);
    await expectLater(
      locked.saveRecoveryCode(locked.newRecoveryCode()),
      throwsA(isA<VaultLockedException>()),
    );
    await expectLater(
      locked.exportSecrets(),
      throwsA(isA<VaultLockedException>()),
    );
    await expectLater(
      locked.restoreSecrets(
        Uint8List(0),
        'code',
        policy: RestoreConflictPolicy.keepExisting,
      ),
      throwsA(isA<VaultLockedException>()),
    );
    // Whether a code exists needs no key.
    expect(await locked.recoveryConfigured(), isFalse);
  });

  test(
    'a vault holding only the recovery entry lets a lost keystore heal',
    () async {
      final directory = await newDirectory();
      final first = await device(directory, _Keystore());
      await _setUpRecovery(first);
      expect(await first.recoveryConfigured(), isTrue);

      // The keystore entry is gone; with no credential to strand, a fresh key
      // is minted rather than every key refused.
      final again = await device(directory, _Keystore());
      expect(again.vaultKey, isNotNull);
      expect(again.vaultKey, isNot(first.vaultKey));
    },
  );

  test('a vault with a credential still refuses a fresh key', () async {
    final directory = await newDirectory();
    final first = await device(directory, _Keystore());
    await first.vault.putSecrets([_secret('pw')]);
    await _setUpRecovery(first);

    await expectLater(
      device(directory, _Keystore()),
      throwsA(isA<MasterKeyUnavailableException>()),
    );
  });

  test('a new code is kept only once saved', () async {
    final a = await freshDevice();
    final code = a.newRecoveryCode();
    expect(await a.recoveryConfigured(), isFalse);

    await a.saveRecoveryCode(code);
    expect(await a.recoveryConfigured(), isTrue);

    // A second code not saved leaves the first in force.
    a.newRecoveryCode();
    await a.vault.putSecrets([_secret('pw')]);
    final export = await a.exportSecrets();
    final b = await freshDevice();
    final summary = await b.restoreSecrets(
      export,
      code,
      policy: RestoreConflictPolicy.keepExisting,
    );
    expect(summary.added, 1);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

const _baseUrl = 'https://sync.test';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

enum _Enrollment { register, login }
enum _ResponseMode { accepted, rejected }
enum _LocalFailure { token, settings }

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  int closes = 0;

  @override
  void close() {
    closes++;
    super.close();
  }
}


/// A keystore that serves reads and ordinary writes but can refuse the vault
/// master key specifically, which is how a locked keyring fails the one write
/// that installs a re-key's new key.
class _SelectiveKeystore extends FlutterSecureStorage {
  _SelectiveKeystore();
  static const _masterKeyName = 'seance.vault.masterKey.v1';
  final Map<String, String> _map = {};
  bool refuseMasterKey = false;
  bool commitMasterKeyBeforeFailure = false;
  bool refuseSyncToken = false;
  Future<void> Function()? afterSyncTokenWrite;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _map[key];

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
    if (refuseSyncToken && key == 'seance.apikey.sync.token') {
      throw PlatformException(code: 'KeyringLocked');
    }
    if (refuseMasterKey && key == _masterKeyName) {
      if (commitMasterKeyBeforeFailure && value != null) _map[key] = value;
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      _map.remove(key);
      return;
    }
    _map[key] = value;
    if (key == 'seance.apikey.sync.token') await afterSyncTokenWrite?.call();
  }

  // Nothing in MasterKeyManager deletes today, but an unstubbed override
  // reaches the real platform channel, which no-ops under the test binding
  // instead of failing — so the fake would diverge silently rather than loudly.
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _map.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-sync-lifetime-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings.syncBaseUrl = _baseUrl;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  for (final enrollment in _Enrollment.values) {
    for (final responseMode in _ResponseMode.values) {
      test('${enrollment.name} ${responseMode.name} closes its client', () async {
        const sharedSecret = Secret(
          id: 'shared',
          kind: SecretKind.password,
          value: 'shared-password',
        );
        await services.vault.putSecret(sharedSecret);
        for (final id in ['first', 'second']) {
          await services.configStore.putServer(ServerConfig(
            id: id,
            label: id,
            host: '$id.test',
            username: 'user',
            secretRef: sharedSecret.id,
            createdAt: 1,
            updatedAt: 1,
          ));
        }
        services.settings.syncUsername = 'old-user';
        await services.saveSettings();
        final oldKey = List<int>.of(services.vaultKey!);
        final transport = _TrackedClient((request) async {
          if (request.url.path == '/v1/prelogin') {
            return http.Response(jsonEncode({
              'argonSalt': base64Encode(List<int>.filled(16, 0)),
              'argonParams': const Argon2Params().toJson(),
            }), HttpStatus.ok);
          }
          if (responseMode == _ResponseMode.rejected) {
            return http.Response('unavailable', HttpStatus.serviceUnavailable);
          }
          if (request.url.path == '/v1/sync') {
            return http.Response(
                jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
                HttpStatus.ok);
          }
          return http.Response(jsonEncode({'token': 'enrolled-token'}),
              HttpStatus.ok);
        });
        final enroll = switch (enrollment) {
          _Enrollment.register => services.registerSync,
          _Enrollment.login => services.loginSync,
        };
        final result = http.runWithClient(
          () => enroll(
            baseUrl: 'https://new-sync.test',
            username: 'user',
            password: 'password',
            encryptionPassphrase: 'password',
          ),
          () => transport,
        );
        if (responseMode == _ResponseMode.rejected) {
          await expectLater(result, throwsA(isA<ApiError>()));
          expect(services.settings.syncBaseUrl, _baseUrl);
          expect(services.settings.syncUsername, 'old-user');
          expect(services.vaultKey, oldKey);
          expect(await services.masterKeys.getApiKey('sync.token'),
              'session-token');
        } else {
          await result;
          expect(await services.masterKeys.getApiKey('sync.token'), 'enrolled-token');
        }
        expect(transport.closes, 1);
        expect((await services.vault.getSecret(sharedSecret.id))?.value,
            sharedSecret.value);
        final reopened = await AppServices.initialize();
        addTearDown(() => reopened.probe.dispose());
        expect((await reopened.vault.getSecret(sharedSecret.id))?.value,
            sharedSecret.value,
            reason: 'shared credentials must remain decryptable after restart');
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  }

  for (final enrollment in _Enrollment.values) {
    test(
      '${enrollment.name} leaves sync disconnected after a refused rekey',
      () async {
        final keystore = _SelectiveKeystore();
        final own = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore),
        );
        addTearDown(() => own.probe.dispose());
        own.settings.syncBaseUrl = 'https://old-sync.test';
        own.settings.syncUsername = 'old-user';
        await own.masterKeys.putApiKey('sync.token', 'old-token');
        await own.saveSettings();
        final oldKey = List<int>.of(own.vaultKey!);
        final paths = <String>[];
        final transport = _TrackedClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/v1/prelogin') {
            return http.Response(
              jsonEncode({
                'argonSalt': base64Encode(List<int>.filled(16, 0)),
                'argonParams': const Argon2Params().toJson(),
              }),
              HttpStatus.ok,
            );
          }
          if (request.url.path == '/v1/sync') {
            return http.Response(
              jsonEncode(
                const PullResponse(records: [], latestSeq: 0).toJson(),
              ),
              HttpStatus.ok,
            );
          }
          return http.Response(
            jsonEncode({'token': 'new-token'}),
            HttpStatus.ok,
          );
        });
        keystore.refuseMasterKey = true;
        final enroll = enrollment == _Enrollment.register
            ? own.registerSync
            : own.loginSync;
        await expectLater(
          http.runWithClient(
            () => enroll(
              baseUrl: _baseUrl,
              username: 'new-user',
              password: 'password',
              encryptionPassphrase: 'password',
            ),
            () => transport,
          ),
          throwsA(isA<KeystoreException>()),
        );

        expect(own.isSyncConfigured, isFalse);
        expect(own.settings.syncUsername, isNull);
        expect(own.vaultKey, oldKey);
        final beforeSync = paths.length;
        await expectLater(
          http.runWithClient(own.runSync, () => transport),
          throwsStateError,
        );
        final reopened = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore),
        );
        addTearDown(() => reopened.probe.dispose());
        expect(reopened.isSyncConfigured, isFalse);
        await expectLater(
          http.runWithClient(reopened.runSync, () => transport),
          throwsStateError,
        );
        expect(
          paths,
          hasLength(beforeSync),
          reason: 'a failed enrollment must not publish with the old vault key',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final failure in _LocalFailure.values) {
    test(
      'failed enrollment ${failure.name} save disconnects until sign-in',
      () async {
        final keystore = _SelectiveKeystore();
        final own = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore),
        );
        addTearDown(() => own.probe.dispose());
        own.settings.syncBaseUrl = 'https://old-sync.test';
        own.settings.syncUsername = 'old-user';
        await own.masterKeys.putApiKey('sync.token', 'old-token');
        await own.saveSettings();
        const secret = Secret(
          id: 'local',
          kind: SecretKind.password,
          value: 'local-password',
        );
        await own.vault.putSecret(secret);
        final oldKey = List<int>.of(own.vaultKey!);
        final blockedSettings = Directory('${own.settingsStore.file.path}.tmp');
        if (failure == _LocalFailure.token) {
          keystore.refuseSyncToken = true;
        } else {
          keystore.afterSyncTokenWrite = () async {
            await blockedSettings.create();
          };
        }
        var requests = 0;
        String? registeredSalt;
        final transport = _TrackedClient((request) async {
          requests++;
          if (request.url.path == '/v1/register') {
            registeredSalt =
                (jsonDecode(request.body) as Map)['argonSalt'] as String;
          }
          if (request.url.path == '/v1/prelogin') {
            return http.Response(
              jsonEncode({
                'argonSalt': registeredSalt,
                'argonParams': const Argon2Params().toJson(),
              }),
              HttpStatus.ok,
            );
          }
          if (request.url.path == '/v1/sync') {
            return http.Response(
              jsonEncode(
                const PullResponse(records: [], latestSeq: 0).toJson(),
              ),
              HttpStatus.ok,
            );
          }
          return http.Response(
            jsonEncode({'token': 'new-token'}),
            HttpStatus.ok,
          );
        });
        await expectLater(
          http.runWithClient(
            () => own.registerSync(
              baseUrl: _baseUrl,
              username: 'new-user',
              password: 'password',
              encryptionPassphrase: 'password',
            ),
            () => transport,
          ),
          failure == _LocalFailure.token
              ? throwsA(isA<KeystoreException>())
              : throwsA(isA<FileSystemException>()),
        );

        expect(
          own.vaultKey,
          isNot(oldKey),
          reason: 'the re-key already succeeded',
        );
        expect((await own.vault.getSecret(secret.id))?.value, secret.value);
        expect(own.isSyncConfigured, isFalse);
        expect(own.settings.syncUsername, isNull);
        final beforeSync = requests;
        await expectLater(
          http.runWithClient(own.runSync, () => transport),
          throwsStateError,
        );
        expect(requests, beforeSync);

        keystore.refuseSyncToken = false;
        keystore.afterSyncTokenWrite = null;
        if (await blockedSettings.exists()) await blockedSettings.delete();
        final reopened = await AppServices.initialize(
          masterKeyManager: MasterKeyManager(keystore),
        );
        addTearDown(() => reopened.probe.dispose());
        expect(reopened.isSyncConfigured, isFalse);
        expect(
          (await reopened.vault.getSecret(secret.id))?.value,
          secret.value,
        );
        await expectLater(
          http.runWithClient(reopened.runSync, () => transport),
          throwsStateError,
        );
        expect(requests, beforeSync);

        // Registration reached the server. Finish that existing account with
        // sign-in, rather than trying to create it a second time.
        await http.runWithClient(
          () => reopened.loginSync(
            baseUrl: _baseUrl,
            username: 'new-user',
            password: 'password',
            encryptionPassphrase: 'password',
          ),
          () => transport,
        );
        expect(reopened.settings.syncBaseUrl, _baseUrl);
        expect(reopened.settings.syncUsername, 'new-user');
        expect(await reopened.masterKeys.getApiKey('sync.token'), 'new-token');
        expect(
          (await reopened.vault.getSecret(secret.id))?.value,
          secret.value,
        );
        await http.runWithClient(reopened.runSync, () => transport);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'enrollment waits for a round and holds the next round until committed',
    () async {
      final keystore = _SelectiveKeystore();
      final own = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore),
      );
      addTearDown(() => own.probe.dispose());
      own.settings.syncBaseUrl = 'https://old-sync.test';
      own.settings.syncUsername = 'old-user';
      await own.masterKeys.putApiKey('sync.token', 'old-token');
      await own.saveSettings();
      final oldKey = List<int>.of(own.vaultKey!);
      final firstRequest = Completer<void>();
      final releaseFirstRound = Completer<void>();
      final tokenWritten = Completer<void>();
      final releaseTokenWrite = Completer<void>();
      keystore.afterSyncTokenWrite = () async {
        tokenWritten.complete();
        await releaseTokenWrite.future;
      };
      final requests = <http.Request>[];
      final transport = _TrackedClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/register') {
          return http.Response(
            jsonEncode({'token': 'new-token'}),
            HttpStatus.ok,
          );
        }
        if (request.url.host == 'old-sync.test') {
          expect(request.headers['authorization'], 'Bearer old-token');
          expect(own.vaultKey, oldKey);
          firstRequest.complete();
          await releaseFirstRound.future;
        } else {
          expect(request.headers['authorization'], 'Bearer new-token');
          expect(own.vaultKey, isNot(oldKey));
          expect(own.settings.syncBaseUrl, _baseUrl);
        }
        return http.Response(
          jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
          HttpStatus.ok,
        );
      });
      final firstRound = http.runWithClient(own.runSync, () => transport);
      await firstRequest.future;
      final enrollment = http.runWithClient(
        () => own.registerSync(
          baseUrl: _baseUrl,
          username: 'new-user',
          password: 'password',
          encryptionPassphrase: 'password',
        ),
        () => transport,
      );
      try {
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));
        expect(own.vaultKey, oldKey);
      } finally {
        releaseFirstRound.complete();
      }
      await firstRound;
      await tokenWritten.future;
      final nextRound = http.runWithClient(own.runSync, () => transport);
      try {
        final beforeSync = requests.length;
        await Future<void>.delayed(Duration.zero);
        expect(
          requests,
          hasLength(beforeSync),
          reason: 'a round must wait until enrollment publishes the endpoint',
        );
        expect(own.isSyncConfigured, isFalse);
      } finally {
        releaseTokenWrite.complete();
      }
      await enrollment;
      await nextRound;
      expect(requests.map((r) => r.url.host), [
        'old-sync.test',
        'sync.test',
        'sync.test',
      ]);
      expect(own.isSyncConfigured, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('successful sync closes its client after consuming the response', () async {
    final transport = _TrackedClient((request) async {
      expect(request.headers['authorization'], 'Bearer session-token');
      return http.Response(
          jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
          HttpStatus.ok);
    });
    await http.runWithClient(services.runSync, () => transport);
    expect(transport.closes, 1);
  });

  test('failed sync closes its client', () async {
    final transport = _TrackedClient((_) async =>
        http.Response('unavailable', HttpStatus.serviceUnavailable));
    await expectLater(http.runWithClient(services.runSync, () => transport),
        throwsA(isA<ApiError>()));
    expect(transport.closes, 1);
  });

  test('malformed prelogin closes its client', () async {
    final transport = _TrackedClient((_) async =>
        http.Response('not-json', HttpStatus.ok));
    await expectLater(
      http.runWithClient(
        () => services.loginSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'password',
        ),
        () => transport,
      ),
      throwsFormatException,
    );
    expect(transport.closes, 1);
  });

  test('weak prelogin is rejected before login and closes its client', () async {
    final paths = <String>[];
    final transport = _TrackedClient((request) async {
      paths.add(request.url.path);
      return http.Response(jsonEncode({
        'argonSalt': base64Encode(List<int>.filled(16, 0)),
        'argonParams': const Argon2Params.fast().toJson(),
      }), HttpStatus.ok);
    });
    await expectLater(
      http.runWithClient(
        () => services.loginSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'password',
        ),
        () => transport,
      ),
      throwsA(isA<StateError>().having(
          (error) => error.message, 'reason', contains('weaker'))),
    );
    expect(paths, ['/v1/prelogin']);
    expect(transport.closes, 1);
  });

  for (final committedBeforeFailure in [false, true]) {
  test('a refused re-key preserves credentials (committed=$committedBeforeFailure)',
      () async {
    final keystore = _SelectiveKeystore();
    final own = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore));
    addTearDown(() => own.probe.dispose());

    final secrets = [
      for (final id in ['alpha', 'beta', 'gamma'])
        Secret(id: id, kind: SecretKind.password, value: 'password-$id'),
    ];
    for (final secret in secrets) {
      await own.vault.putSecret(secret);
      await own.configStore.putServer(ServerConfig(
        id: secret.id,
        label: secret.id,
        host: '${secret.id}.test',
        username: 'user',
        secretRef: secret.id,
        createdAt: 1,
        updatedAt: 1,
      ));
    }

    final transport = _TrackedClient((request) async {
      if (request.url.path == '/v1/prelogin') {
        return http.Response(jsonEncode({
          'argonSalt': base64Encode(List<int>.filled(16, 0)),
          'argonParams': const Argon2Params().toJson(),
        }), HttpStatus.ok);
      }
      if (request.url.path == '/v1/sync') {
        return http.Response(
            jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
            HttpStatus.ok);
      }
      return http.Response(
          jsonEncode({'token': 'enrolled-token'}), HttpStatus.ok);
    });

    // The vault file re-seals fine; the keyring refuses the one write that
    // would make the new key survive a restart.
    keystore.refuseMasterKey = true;
    keystore.commitMasterKeyBeforeFailure = committedBeforeFailure;
    await expectLater(
      http.runWithClient(
        () => own.registerSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'separate-encryption-passphrase',
        ),
        () => transport,
      ),
      throwsA(isA<KeystoreException>()),
    );

    // The keyring's own diagnosis has to survive the failure. Deciding which
    // key survived means reading the keystore from inside this catch, and a
    // read that reported health would mark it *available* again — clearing
    // the `KeyringLocked` the refused write just recorded, which is what the
    // bootstrap toast's retry affordance keys off.
    expect(own.masterKeys.keystoreStatus, KeystoreStatus.unavailable);
    expect(own.masterKeys.lastKeystoreError, contains('KeyringLocked'));

    // The keystore still holds the original key, so that is the key the file
    // has to be readable with. Leaving it under the uninstalled one would put
    // every credential out of reach of the next launch.
    final reopened = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore));
    addTearDown(() => reopened.probe.dispose());
    for (final secret in secrets) {
      expect((await reopened.vault.getSecret(secret.id))!.value, secret.value);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  }

}

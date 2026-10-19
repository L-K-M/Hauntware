import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keystore/ghost_keystore.dart';
import 'package:planchette_app/services/workspace_catalog.dart';
import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';

const _baseUrl = 'https://catalog.example';
const _username = 'owner';
const _password = 'account passphrase';
const _secretValue = 'private fixture password';
final _salt = List<int>.filled(16, 7);

void main() {
  late VaultKeys accountKeys;
  late Directory directory;
  late _MasterKeys masterKeys;
  late _Server server;
  late WorkspaceCatalog catalog;

  setUpAll(() async {
    accountKeys = await VaultCrypto.deriveKeys(
      passphrase: _password,
      salt: _salt,
      params: Argon2Params.minimum,
    );
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'workspace-catalog-test-',
    );
    masterKeys = _MasterKeys();
    server = _Server(accountKeys);
    catalog = WorkspaceCatalog(
      directory: directory,
      masterKeys: masterKeys,
      transportFactory: server.transport,
    );
  });

  tearDown(() async {
    catalog.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> signIn({
    String baseUrl = _baseUrl,
    String username = _username,
    String passphrase = _password,
    WorkspaceCredentialSync credentials = WorkspaceCredentialSync.disabled,
  }) => catalog.signIn(
    baseUrl: baseUrl,
    username: username,
    password: _password,
    encryptionPassphrase: passphrase,
    credentialSync: credentials,
  );

  test(
    'unenrolled load and secret read do not access keys, network or disk writes',
    () async {
      await catalog.load();
      expect(await catalog.secretById('password'), isNull);
      expect(catalog.servers, isEmpty);
      expect(catalog.account, isNull);
      expect(catalog.credentialSync, WorkspaceCredentialSync.disabled);
      expect(masterKeys.probes, 0);
      expect(masterKeys.apiReads, 0);
      expect(server.transports, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'enrollment persists cached catalog, consent and device id without plaintext secrets',
    () async {
      await server.seedServer();
      await signIn(baseUrl: '$_baseUrl/', username: ' $_username ');
      expect(catalog.serverById('alpha')?.host, 'alpha.example');
      expect(catalog.account?.baseUrl, _baseUrl);
      expect(catalog.account?.mode, SyncAccountMode.shared);
      expect(catalog.notices, isEmpty);
      expect(server.registers, 0);

      final stateFile = File('${directory.path}/state.json');
      final before = jsonDecode(await stateFile.readAsString()) as Map;
      final probes = masterKeys.probes;
      final requests = server.transports.length;
      final reopened = WorkspaceCatalog(
        directory: directory,
        masterKeys: masterKeys,
        transportFactory: server.transport,
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.servers.single.id, 'alpha');
      expect(masterKeys.probes, probes);
      expect(server.transports.length, requests);
      await reopened.sync();
      expect(server.transports.last.$2, _Server.sessionToken);
      final after = jsonDecode(await stateFile.readAsString()) as Map;
      expect(after['deviceId'], before['deviceId']);
      expect(before['deviceId'], isNotEmpty);

      for (final entry in await directory.list().toList()) {
        expect(entry, isA<File>());
        final bytes = await (entry as File).readAsString();
        expect(bytes, isNot(contains(_Server.sessionToken)));
        expect(bytes, isNot(contains(_password)));
        expect(bytes, isNot(contains(_secretValue)));
      }
    },
  );

  test(
    'account switches and invalid URLs fail before transport or key access',
    () async {
      await server.seedServer();
      await signIn();
      final requests = server.transports.length;
      final probes = masterKeys.probes;
      for (final request in [
        signIn(baseUrl: 'https://other.example'),
        signIn(username: 'another-owner'),
        signIn(baseUrl: '$_baseUrl?redirect=elsewhere'),
        signIn(baseUrl: 'https://user:password@catalog.example'),
      ]) {
        await expectLater(
          request,
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
      }
      expect(server.transports.length, requests);
      expect(masterKeys.probes, probes);
      expect(catalog.account?.username, _username);
    },
  );

  test('rounds remain pull-only even with preexisting dirty records', () async {
    final dirty = await server.seal(
      'unknown:pending',
      RecordKind.serverConfig,
      {},
    );
    await PersistentLocalRecordStore(
      path: '${directory.path}/sync_records.json',
    ).putLocal(dirty);
    await server.seedServer();
    await signIn();
    await catalog.sync();
    expect(server.pushes, 0);
    expect(server.cursors.first, 0);
    expect(
      (await PersistentLocalRecordStore(
        path: '${directory.path}/sync_records.json',
      ).dirtyRecords()).single.id,
      dirty.id,
    );
  });

  test(
    'same-account re-signin opts into cached secrets and disabling preserves them',
    () async {
      await server.seedServer();
      await server.seedSecret();
      await signIn();
      expect(await catalog.secretById('password'), isNull);
      final store = FileVaultStore(File('${directory.path}/vault.json'));
      expect(await store.allSecretBlobs(), isEmpty);

      await signIn(credentials: WorkspaceCredentialSync.enabled);
      expect((await catalog.secretById('password'))?.value, _secretValue);
      final reopened = WorkspaceCatalog(
        directory: directory,
        masterKeys: masterKeys,
        transportFactory: server.transport,
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.credentialSync, WorkspaceCredentialSync.enabled);
      expect((await reopened.secretById('password'))?.value, _secretValue);

      await signIn();
      expect((await catalog.secretById('password'))?.value, _secretValue);
      final preserved = FileVaultStore(File('${directory.path}/vault.json'));
      expect(await preserved.getSecretBlob('password'), isNotNull);
      expect(server.pushes, 0);
    },
  );

  test(
    'credential write failures surface and refresh retries records behind the cursor',
    () async {
      await server.seedServer();
      await server.seedSecret();
      await signIn();
      // A directory at the vault destination makes the atomic rename fail on every OS.
      await File('${directory.path}/vault.json').delete();
      final blockedVault = await Directory(
        '${directory.path}/vault.json',
      ).create();
      await expectLater(
        signIn(credentials: WorkspaceCredentialSync.enabled),
        throwsStateError,
      );
      expect(catalog.error, contains('credentials could not sync'));
      expect(catalog.notices.join(), contains('credentials could not sync'));
      expect(catalog.account, isNotNull);
      await blockedVault.delete();
      await catalog.sync();
      expect((await catalog.secretById('password'))?.value, _secretValue);
      expect(
        catalog.notices.join(),
        isNot(contains('credentials could not sync')),
      );
      expect(server.pushes, 0);
    },
  );

  test(
    'wrong encryption passphrase preserves enrollment and the working vault key',
    () async {
      await server.seedServer();
      await signIn();
      final key = List<int>.of(masterKeys.key!);
      final token = masterKeys.token;
      await expectLater(
        signIn(passphrase: 'incorrect encryption passphrase'),
        throwsStateError,
      );
      expect(masterKeys.key, key);
      expect(masterKeys.token, token);
      expect(catalog.serverById('alpha'), isNotNull);
      expect(catalog.notices.join(), contains('could not decrypt'));
      await signIn();
      expect(catalog.notices, isEmpty);
    },
  );

  test(
    'rejected sessions and strict decode tripwires survive reopening',
    () async {
      await server.seedServer();
      server.add(
        await server.seal('malformed-server', RecordKind.serverConfig, {
          'id': 'different-id',
        }),
      );
      await signIn();
      expect(catalog.servers, hasLength(1));
      expect(catalog.notices.join(), contains('newer schema'));
      server.pullError = const ApiError(
        code: 'unauthorized',
        message: 'Session revoked',
      );
      await expectLater(catalog.sync(), throwsStateError);
      expect(catalog.notices.join(), contains('session was rejected'));
      final reopened = WorkspaceCatalog(
        directory: directory,
        masterKeys: masterKeys,
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.notices.join(), contains('session was rejected'));
      expect(reopened.notices.join(), contains('newer schema'));
      expect(reopened.servers.single.id, 'alpha');
    },
  );

  test('synced host-key conflicts keep the locally trusted key', () async {
    await server.seedServer();
    final local = HostKey(
      host: 'alpha.example',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'local-fingerprint',
      pinnedAt: 1,
    );
    final remote = HostKey(
      host: local.host,
      port: local.port,
      type: local.type,
      fingerprintSha256: 'remote-fingerprint',
      pinnedAt: 2,
    );
    await catalog.hostKeys.put(local);
    server.add(
      await server.seal(remote.recordId, RecordKind.hostKey, remote.toJson()),
    );
    await signIn();
    expect(
      (await catalog.hostKeys.get(local.host, local.port))?.fingerprintSha256,
      local.fingerprintSha256,
    );
    expect(
      catalog.hostKeyConflicts.single.pulled.fingerprintSha256,
      remote.fingerprintSha256,
    );
    expect(catalog.notices.join(), contains('Local keys remain trusted'));
    final reopened = WorkspaceCatalog(
      directory: directory,
      masterKeys: masterKeys,
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.notices.join(), contains('Local keys remain trusted'));
  });

  test(
    'newer and malformed enrollment state fail closed without rewriting',
    () async {
      await server.seedServer();
      await signIn();
      final file = File('${directory.path}/state.json');
      final original =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final invalid in [
        {...original, 'version': 2},
        {...original, 'credentialSync': 'future-consent'},
        {...original, 'deviceId': null},
        {
          ...original,
          'account': {...original['account'] as Map, 'mode': 'future-mode'},
        },
      ]) {
        final contents = jsonEncode(invalid);
        await file.writeAsString(contents);
        final probes = masterKeys.probes;
        final requests = server.transports.length;
        final reopened = WorkspaceCatalog(
          directory: directory,
          masterKeys: masterKeys,
          transportFactory: server.transport,
        );
        await expectLater(reopened.load(), throwsFormatException);
        await expectLater(
          reopened.signIn(
            baseUrl: _baseUrl,
            username: _username,
            password: _password,
            encryptionPassphrase: _password,
            credentialSync: WorkspaceCredentialSync.disabled,
          ),
          throwsFormatException,
        );
        expect(await file.readAsString(), contents);
        expect(masterKeys.probes, probes);
        expect(server.transports.length, requests);
        reopened.dispose();
      }
    },
  );

  test(
    'a vault or recovery journal without its key never mints a replacement',
    () async {
      masterKeys.key = null;
      final file = File('${directory.path}/vault.json.rekey');
      await file.writeAsString('preserve recovery evidence');
      await expectLater(
        signIn(),
        throwsA(isA<MasterKeyUnavailableException>()),
      );
      expect(await file.readAsString(), 'preserve recovery evidence');
      expect(masterKeys.key, isNull);
      expect(masterKeys.lastHasVault, isTrue);
      expect(server.transports, isEmpty);
    },
  );

  for (final wroteBeforeFailure in [false, true]) {
    test(
      'rekey failure preserves every vault entry (write-before-error: $wroteBeforeFailure)',
      () async {
        await server.seedServer();
        final oldKey = List<int>.of(masterKeys.key!);
        final vaultFile = File('${directory.path}/vault.json');
        await SecretVault(FileVaultStore(vaultFile), oldKey).putSecret(
          const Secret(
            id: 'orphan',
            kind: SecretKind.password,
            value: _secretValue,
          ),
        );
        masterKeys.failKeyWrite = true;
        masterKeys.writeBeforeFailure = wroteBeforeFailure;
        await expectLater(signIn(), throwsA(isA<KeystoreException>()));
        expect(
          (await SecretVault(
            FileVaultStore(vaultFile),
            masterKeys.key!,
          ).getSecret('orphan'))?.value,
          _secretValue,
        );
        expect(catalog.account, isNull);
        expect(await File('${vaultFile.path}.rekey').exists(), isFalse);
      },
    );
  }

  test(
    'token write failure is explicit and never persists enrollment',
    () async {
      await server.seedServer();
      masterKeys.failTokenWrite = true;
      await expectLater(signIn(), throwsA(isA<KeystoreException>()));
      expect(catalog.error, contains('token unavailable'));
      expect(catalog.account, isNull);
      expect(await File('${directory.path}/state.json').exists(), isFalse);
      expect(
        await File('${directory.path}/sync_records.json').exists(),
        isFalse,
      );
      masterKeys.failTokenWrite = false;
      await signIn();
      expect(catalog.account?.username, _username);
    },
  );

  test('auth failure and KDF downgrade never persist enrollment', () async {
    server.loginError = const ApiError(
      code: 'invalid_credentials',
      message: 'Invalid account password',
    );
    await expectLater(signIn(), throwsA(isA<ApiError>()));
    expect(catalog.error, contains('Invalid account password'));
    expect(catalog.account, isNull);
    expect(masterKeys.token, isNull);

    server.loginError = null;
    server.parameters = const Argon2Params.fast();
    await expectLater(signIn(), throwsA(isA<KdfDowngradeException>()));
    expect(catalog.account, isNull);
    expect(masterKeys.token, isNull);
    expect(server.cursors, isEmpty);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'an empty account persists the unverified notice until records arrive',
    () async {
      await signIn();
      expect(catalog.notices.join(), contains('not yet been verified'));
      final reopened = WorkspaceCatalog(
        directory: directory,
        masterKeys: masterKeys,
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.notices.join(), contains('not yet been verified'));
      await server.seedServer();
      await catalog.sync();
      expect(catalog.notices, isEmpty);
      expect(catalog.servers.single.id, 'alpha');
    },
  );

  test(
    'startup settles a pending rekey against the key actually installed',
    () async {
      await server.seedServer();
      final file = File('${directory.path}/vault.json');
      final store = FileVaultStore(file);
      await SecretVault(store, masterKeys.key!).putSecret(
        const Secret(
          id: 'orphan',
          kind: SecretKind.password,
          value: _secretValue,
        ),
      );
      await store.stageRekey(
        currentKey: masterKeys.key!,
        newKey: accountKeys.vaultKey,
      );
      masterKeys.key = List.of(accountKeys.vaultKey);
      await signIn();
      expect((await catalog.secretById('orphan'))?.value, _secretValue);
      expect(await File('${file.path}.rekey').exists(), isFalse);
    },
  );

  test('transport creation failure removes enrollment staging files', () async {
    final failing = WorkspaceCatalog(
      directory: directory,
      masterKeys: masterKeys,
      transportFactory: (String baseUrl, {String? token}) =>
          throw StateError('transport unavailable'),
    );
    addTearDown(failing.dispose);
    await expectLater(
      failing.signIn(
        baseUrl: _baseUrl,
        username: _username,
        password: _password,
        encryptionPassphrase: _password,
        credentialSync: WorkspaceCredentialSync.disabled,
      ),
      throwsStateError,
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('operations serialize and recover after an error', () async {
    await server.seedServer();
    await signIn();
    final entered = Completer<void>();
    final release = Completer<void>();
    server.beforePull = () async {
      entered.complete();
      await release.future;
      server.beforePull = null;
    };
    final first = catalog.sync();
    await entered.future;
    final transports = server.transports.length;
    final second = catalog.sync();
    expect(catalog.busy, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(server.transports.length, transports);
    release.complete();
    await Future.wait([first, second]);
    expect(catalog.busy, isFalse);
    expect(catalog.error, isNull);
    expect(server.closed, server.transports.length);
  });
}

final class _MasterKeys extends MasterKeyManager {
  _MasterKeys()
    : super(masterKeyEntry: 'test.vault', apiKeyPrefix: 'test.api.');
  List<int>? key = List<int>.filled(32, 9);
  String? token;
  int probes = 0;
  int apiReads = 0;
  bool lastHasVault = false;
  bool failKeyWrite = false;
  bool writeBeforeFailure = false;
  bool failTokenWrite = false;

  @override
  Future<List<int>?> probeKeystore({bool hasExistingVault = false}) async {
    probes++;
    lastHasVault = hasExistingVault;
    if (key == null && hasExistingVault) {
      throw const MasterKeyUnavailableException();
    }
    return key ??= List<int>.filled(32, 9);
  }

  @override
  Future<void> setKeystoreKey(List<int> value) async {
    if (!failKeyWrite || writeBeforeFailure) key = List.of(value);
    if (failKeyWrite) throw const KeystoreException('key unavailable');
  }

  @override
  Future<void> putApiKey(String name, String value) async {
    expect(name, 'sync.token');
    if (failTokenWrite) throw const KeystoreException('token unavailable');
    token = value;
  }

  @override
  Future<String?> getApiKey(String name) async {
    expect(name, 'sync.token');
    apiReads++;
    return token;
  }
}

final class _Server {
  _Server(this.keys);
  static const sessionToken = 'catalog-session-token';
  final VaultKeys keys;
  final records = <EncryptedRecord>[];
  final transports = <(String, String?)>[];
  final cursors = <int>[];
  int registers = 0;
  int pushes = 0;
  int closed = 0;
  ApiError? pullError;
  ApiError? loginError;
  Argon2Params parameters = Argon2Params.minimum;
  Future<void> Function()? beforePull;

  WorkspaceCatalogTransport transport(String baseUrl, {String? token}) {
    transports.add((baseUrl, token));
    return _Transport(this, token);
  }

  Future<EncryptedRecord> seal(
    String id,
    RecordKind kind,
    Map<String, dynamic> data,
  ) => RecordCodec(keys.vaultKey).encrypt(
    DecryptedRecord(
      id: id,
      kind: kind,
      updatedAt: records.length + 1,
      deviceId: 'another-device',
      data: data,
    ),
  );

  void add(EncryptedRecord record) =>
      records.add(record.withSeq(records.length + 1));

  Future<void> seedServer() async {
    final config = ServerConfig(
      id: 'alpha',
      label: 'Production',
      host: 'alpha.example',
      username: 'alice',
      port: 22,
      authMethod: AuthMethod.password,
      secretRef: 'password',
      syncSecret: true,
      createdAt: 1,
      updatedAt: 1,
    );
    add(await seal(config.id, RecordKind.serverConfig, config.toJson()));
  }

  Future<void> seedSecret() async {
    const secret = Secret(
      id: 'password',
      kind: SecretKind.password,
      value: _secretValue,
    );
    add(await seal('secret:${secret.id}', RecordKind.secret, secret.toJson()));
  }
}

final class _Transport implements WorkspaceCatalogTransport {
  _Transport(this.server, this.token);
  final _Server server;
  @override
  String? token;

  @override
  Future<PreloginResponse> prelogin(String username) async => PreloginResponse(
    argonSalt: base64Encode(_salt),
    argonParams: server.parameters,
  );
  @override
  Future<void> login(LoginRequest request) async {
    final error = server.loginError;
    if (error != null) throw error;
    if (request.username != _username ||
        request.authVerifier != base64Encode(server.keys.authVerifier)) {
      throw const ApiError(
        code: 'invalid_credentials',
        message: 'Invalid credentials',
      );
    }
    token = _Server.sessionToken;
  }

  @override
  Future<void> register(RegisterRequest request) async {
    server.registers++;
    throw UnsupportedError('No registration');
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    await server.beforePull?.call();
    server.cursors.add(since);
    final error = server.pullError;
    if (error != null) throw error;
    return PullResponse(
      records: server.records.where((record) => record.seq! > since).toList(),
      latestSeq: server.records.length,
    );
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    server.pushes++;
    throw StateError('Pull-only catalog tried to push');
  }

  @override
  void close() => server.closed++;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Account _account(String username, String generation) => Account(
      username: username,
      generation: generation,
      authVerifierHash: 'hash',
      verifierSalt: base64.encode(const [1, 2, 3]),
      argonSalt: base64.encode(List<int>.filled(16, 4)),
      argonParams: const Argon2Params(),
      vaultKeyCheck: base64.encode(List<int>.filled(64, 5)),
    );

Account _legacyAccount(String username, String generation) => Account(
      username: username,
      generation: generation,
      authVerifierHash: 'hash',
      verifierSalt: base64.encode(const [1, 2, 3]),
      argonSalt: base64.encode(List<int>.filled(16, 4)),
      argonParams: const Argon2Params(),
    );

Future<void> _exerciseSessions(Storage storage) async {
  final first = await storage.registerAccount(
    _account('alice', 'generation-a'),
    issuedAt: 100,
    expiresAt: 200,
    maxSessions: 2,
  );
  expect(first, isNotNull);
  expect(await storage.principalForToken(first!, now: 199), isNotNull);
  expect(await storage.principalForToken(first, now: 200), isNull);

  final account = (await storage.getAccount('alice'))!;
  final second = await storage.createTokenFor(
    account,
    issuedAt: 201,
    expiresAt: 301,
    maxSessions: 2,
  );
  final third = await storage.createTokenFor(
    account,
    issuedAt: 202,
    expiresAt: 302,
    maxSessions: 2,
  );
  final fourth = await storage.createTokenFor(
    account,
    issuedAt: 203,
    expiresAt: 303,
    maxSessions: 2,
  );
  expect(await storage.principalForToken(second!, now: 203), isNull,
      reason: 'the oldest live session is evicted at the account cap');
  expect(await storage.principalForToken(third!, now: 203), isNotNull);

  final fourthPrincipal =
      (await storage.principalForToken(fourth!, now: 203))!;
  expect(await storage.revokeSession(fourthPrincipal), isTrue);
  expect(await storage.principalForToken(fourth, now: 203), isNull);

  final thirdPrincipal = (await storage.principalForToken(third, now: 203))!;
  expect(await storage.revokeAllSessions(thirdPrincipal), isTrue);
  expect(await storage.principalForToken(third, now: 203), isNull);
}

class _SignalingStorage extends InMemoryStorage {
  Completer<void> authenticated = Completer<void>();

  void resetSignal() => authenticated = Completer<void>();

  @override
  Future<AuthPrincipal?> principalForToken(String token,
      {required int now}) async {
    final principal = await super.principalForToken(token, now: now);
    if (!authenticated.isCompleted) authenticated.complete();
    return principal;
  }
}

Future<Response> _request(
  Handler handler,
  String method,
  String path, {
  String? token,
  Object? body,
}) async =>
    await handler(Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        'content-type': 'application/json',
        'x-seance-protocol-version': '$kProtocolVersion',
        if (token != null) 'authorization': 'Bearer $token',
      },
      body: body == null ? null : jsonEncode(body),
    ));

Future<String> _register(Handler handler, String username) async {
  final response = await _request(
    handler,
    'POST',
    '/v1/register',
    body: RegisterRequest(
      username: username,
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params(),
      vaultKeyCheck: base64.encode(secureRandomBytes(64)),
    ).toJson(),
  );
  expect(response.statusCode, 200);
  return LoginResponse.fromJson(
          (jsonDecode(await response.readAsString()) as Map).cast())
      .token;
}

void main() {
  test('in-memory sessions expire, cap, and revoke', () async {
    await _exerciseSessions(InMemoryStorage());
  });

  test('SQLite stores only token digests and enforces session policy',
      () async {
    final database = sqlite3.openInMemory();
    final storage = SqliteStorage(database);
    addTearDown(storage.close);

    final raw = await storage.registerAccount(
      _account('bob', 'generation-b'),
      issuedAt: 100,
      expiresAt: 200,
      maxSessions: 2,
    );
    expect(raw, isNotNull);
    final tokenRows = database.select('SELECT token_digest FROM tokens');
    expect(tokenRows.single['token_digest'], isNot(raw));
    expect(database.select('SELECT * FROM tokens WHERE token_digest = ?', [raw]),
        isEmpty);

    await storage.deleteAccount('bob');
    await _exerciseSessions(storage);
  });

  test('opening a legacy database invalidates plaintext bearer tokens',
      () async {
    final database = sqlite3.openInMemory();
    database.execute('''
      CREATE TABLE accounts (
        username TEXT PRIMARY KEY,
        auth_verifier_hash TEXT NOT NULL,
        verifier_salt TEXT NOT NULL,
        argon_salt TEXT NOT NULL,
        argon_params TEXT NOT NULL
      );
      CREATE TABLE tokens (token TEXT PRIMARY KEY, username TEXT NOT NULL);
      INSERT INTO accounts VALUES (
        'legacy', 'hash', 'salt', 'argon',
        '{"memory":19456,"iterations":2,"parallelism":1,"hashLength":32}'
      );
      INSERT INTO tokens VALUES ('permanent-secret', 'legacy');
    ''');

    final storage = SqliteStorage(database);
    addTearDown(storage.close);
    expect(await storage.usernameForToken('permanent-secret'), isNull);
    expect(database.select('SELECT * FROM tokens'), isEmpty);
    expect((await storage.getAccount('legacy'))!.generation, isNotEmpty);
  });

  test('migration repairs an existing nullable generation idempotently',
      () async {
    final directory = Directory.systemTemp.createTempSync('session-migrate-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/sync.sqlite';
    final database = sqlite3.open(path);
    database.execute('''
      CREATE TABLE accounts (
        username TEXT PRIMARY KEY,
        generation TEXT,
        auth_verifier_hash TEXT NOT NULL,
        verifier_salt TEXT NOT NULL,
        argon_salt TEXT NOT NULL,
        argon_params TEXT NOT NULL,
        vault_key_check TEXT
      );
      INSERT INTO accounts VALUES (
        'partial', NULL, 'hash', 'salt', 'argon',
        '{"memory":19456,"iterations":2,"parallelism":1,"hashLength":32}',
        NULL
      );
    ''');

    database.close();

    var storage = SqliteStorage.open(path);
    final generation = (await storage.getAccount('partial'))!.generation;
    expect(generation, isNotEmpty);
    storage.close();

    // Re-run the constructor migration over the repaired schema. It must keep
    // the identity stable, not mistake the nullable declaration for bad data.
    storage = SqliteStorage.open(path);
    addTearDown(storage.close);
    expect((await storage.getAccount('partial'))!.generation, generation);
  });

  test('the server rejects a session at its exclusive expiry', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    final handler = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(
        openRegistration: true,
        sessionDuration: Duration(seconds: 1),
      ),
      now: () => now,
    ).handler;
    final token = await _register(handler, 'expiring');
    now = DateTime.fromMillisecondsSinceEpoch(1999, isUtc: true);
    expect((await _request(handler, 'GET', '/v1/sync', token: token)).statusCode,
        200);
    now = DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true);
    expect((await _request(handler, 'GET', '/v1/sync', token: token)).statusCode,
        401);
  });

  test('SQLite rejects an old principal after another connection re-registers',
      () async {
    final directory = Directory.systemTemp.createTempSync('session-race-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/sync.sqlite';
    final first = SqliteStorage.open(path);
    final second = SqliteStorage.open(path);
    addTearDown(first.close);
    addTearDown(second.close);

    final token = (await first.registerAccount(
      _account('raced', 'old-generation'),
      issuedAt: 1,
      expiresAt: 100,
      maxSessions: 2,
    ))!;
    final oldPrincipal =
        (await first.principalForToken(token, now: 2))!;
    expect(await second.deleteAccountFor(oldPrincipal), isTrue);
    expect(
      await second.registerAccount(
        _account('raced', 'new-generation'),
        issuedAt: 3,
        expiresAt: 100,
        maxSessions: 2,
      ),
      isNotNull,
    );

    await expectLater(
      first.pushRecordsFor(oldPrincipal, [
        EncryptedRecord(
          id: 'late',
          updatedAt: 1,
          deviceId: 'old-device',
          deleted: false,
          seq: null,
          blob: Uint8List.fromList([1]),
        ),
      ]),
      throwsA(isA<StalePrincipalException>()),
    );
    expect(await second.getRecord('raced', 'late'), isNull);
  });

  test('an empty legacy account initializes its key check exactly once',
      () async {
    final storage = InMemoryStorage();
    final token = (await storage.registerAccount(
      _legacyAccount('legacy-empty', 'generation'),
      issuedAt: 1,
      expiresAt: 100,
      maxSessions: 2,
    ))!;
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(),
      now: () => DateTime.fromMillisecondsSinceEpoch(2),
    ).handler;
    final firstCheck = base64.encode(List<int>.filled(64, 7));
    final first = await _request(
      handler,
      'PUT',
      '/v1/account/vault-key-check',
      token: token,
      body: {'vaultKeyCheck': firstCheck},
    );
    expect(first.statusCode, 200);
    expect(jsonDecode(await first.readAsString())['vaultKeyCheck'], firstCheck);

    final second = await _request(
      handler,
      'PUT',
      '/v1/account/vault-key-check',
      token: token,
      body: {'vaultKeyCheck': base64.encode(List<int>.filled(64, 8))},
    );
    expect(second.statusCode, 200);
    expect(jsonDecode(await second.readAsString())['vaultKeyCheck'], firstCheck,
        reason: 'a concurrent or repeated initializer must verify the winner');
  });

  test('SQLite initializes an empty legacy account in the auth transaction',
      () async {
    final storage = SqliteStorage.open(':memory:');
    addTearDown(storage.close);
    final token = (await storage.registerAccount(
      _legacyAccount('sqlite-legacy', 'generation'),
      issuedAt: 1,
      expiresAt: 100,
      maxSessions: 2,
    ))!;
    final principal = (await storage.principalForToken(token, now: 2))!;
    final check = base64.encode(List<int>.filled(64, 7));
    expect(await storage.initializeVaultKeyCheckFor(principal, check), check);
    expect((await storage.getAccount('sqlite-legacy'))!.vaultKeyCheck, check);
  });

  test('a non-empty legacy account cannot initialize without record proof',
      () async {
    final storage = InMemoryStorage();
    final token = (await storage.registerAccount(
      _legacyAccount('legacy-full', 'generation'),
      issuedAt: 1,
      expiresAt: 100,
      maxSessions: 2,
    ))!;
    await storage.pushRecords('legacy-full', [
      EncryptedRecord(
        id: 'record',
        updatedAt: 1,
        deviceId: 'device',
        deleted: false,
        seq: null,
        blob: Uint8List.fromList([1]),
      ),
    ]);
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(),
      now: () => DateTime.fromMillisecondsSinceEpoch(2),
    ).handler;
    final response = await _request(
      handler,
      'PUT',
      '/v1/account/vault-key-check',
      token: token,
      body: {'vaultKeyCheck': base64.encode(List<int>.filled(64, 7))},
    );
    expect(response.statusCode, 409);
    expect(jsonDecode(await response.readAsString())['error'],
        'account_not_empty');
  });

  test('a revoked session cannot finish a push whose body was held',
      () async {
    final storage = _SignalingStorage();
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(openRegistration: true),
    ).handler;
    final token = await _register(handler, 'revoked');

    storage.resetSignal();
    final body = StreamController<List<int>>();
    final pending = handler(Request(
      'PUT',
      Uri.parse('http://localhost/v1/records'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $token',
      },
      body: body.stream,
    ));
    await storage.authenticated.future;
    final logout =
        await _request(handler, 'DELETE', '/v1/session', token: token);
    expect(logout.statusCode, 204);

    body.add(utf8.encode(jsonEncode(PushRequest(records: [
      EncryptedRecord(
        id: 'late',
        updatedAt: 1,
        deviceId: 'device',
        deleted: false,
        seq: null,
        blob: Uint8List.fromList([1]),
      ),
    ]).toJson())));
    await body.close();
    expect((await pending).statusCode, 401);
    expect(await storage.getRecord('revoked', 'late'), isNull);
  });

  test('an old request cannot mutate a replacement account generation',
      () async {
    final storage = _SignalingStorage();
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(openRegistration: true),
    ).handler;
    final oldToken = await _register(handler, 'reused');

    storage.resetSignal();
    final body = StreamController<List<int>>();
    final pending = handler(Request(
      'PUT',
      Uri.parse('http://localhost/v1/records'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $oldToken',
      },
      body: body.stream,
    ));
    await storage.authenticated.future;
    expect((await _request(handler, 'DELETE', '/v1/account', token: oldToken))
        .statusCode, 200);
    await _register(handler, 'reused');

    body.add(utf8.encode(jsonEncode(PushRequest(records: [
      EncryptedRecord(
        id: 'late',
        updatedAt: 1,
        deviceId: 'old-device',
        deleted: false,
        seq: null,
        blob: Uint8List.fromList([1]),
      ),
    ]).toJson())));
    await body.close();
    expect((await pending).statusCode, 401);
    expect(await storage.getRecord('reused', 'late'), isNull);
  });
}

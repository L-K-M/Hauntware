import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _AccountReadBarrier {
  var _waiting = 0;
  final _bothWaiting = Completer<void>();

  Future<Account?> hold(Future<Account?> read) async {
    final account = await read;
    if (account != null) return account;

    _waiting++;
    if (_waiting == 2) _bothWaiting.complete();
    await _bothWaiting.future;
    return null;
  }
}

class _RacingMemoryStorage extends InMemoryStorage {
  final _barrier = _AccountReadBarrier();

  @override
  Future<Account?> getAccount(String username) =>
      _barrier.hold(super.getAccount(username));
}

class _RacingSqliteStorage extends SqliteStorage {
  final _barrier = _AccountReadBarrier();

  _RacingSqliteStorage(super.database);

  @override
  Future<Account?> getAccount(String username) =>
      _barrier.hold(super.getAccount(username));
}

class _Reply {
  final int status;
  final Map<String, dynamic> body;

  const _Reply(this.status, this.body);
}

RegisterRequest _registration(String username) => RegisterRequest(
  username: username,
  authVerifier: base64.encode(secureRandomBytes(32)),
  argonSalt: base64.encode(secureRandomBytes(16)),
  argonParams: const Argon2Params(),
);

Account _account(String username, String marker) => Account(
  username: username,
  authVerifierHash: 'hash-$marker',
  verifierSalt: 'verifier-$marker',
  argonSalt: 'argon-$marker',
  argonParams: const Argon2Params(),
);

EncryptedRecord _record(String marker, int seq) => EncryptedRecord(
  id: 'record-$marker',
  updatedAt: seq,
  deviceId: 'device-$marker',
  deleted: false,
  seq: seq,
  blob: Uint8List.fromList(utf8.encode('blob-$marker')),
);

StoredInboxApp _inboxApp(String username, String marker) => StoredInboxApp(
  username: username,
  appId: 'app-$marker',
  name: 'App $marker',
  tokenHash: 'token-hash-$marker',
  tokenSalt: 'token-salt-$marker',
  created: 1,
);

Future<String> _seedOwnedState(
  Storage storage,
  String username,
  String marker,
) async {
  final token = await storage.createToken(username);
  final seq = await storage.nextSeq(username);
  await storage.putRecord(username, _record(marker, seq));
  final app = _inboxApp(username, marker);
  expect(await storage.createInboxApp(app), isTrue);
  expect(
    (await storage.addInboxItem(
      app.appId,
      'item-$marker',
      Uint8List.fromList([1, 2, 3]),
      storedAt: 1,
      maxPending: 10,
    )).status,
    InboxAddStatus.added,
  );
  return token;
}

Future<_Reply> _post(
  Handler handler,
  String path,
  Map<String, dynamic> body,
) async {
  final response = await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    ),
  );
  return _Reply(
    response.statusCode,
    jsonDecode(await response.readAsString()) as Map<String, dynamic>,
  );
}

void main() {
  for (final backend in ['in-memory', 'SQLite']) {
    test('concurrent same-name registration is atomic with $backend', () async {
      late final Storage storage;
      if (backend == 'in-memory') {
        storage = _RacingMemoryStorage();
      } else {
        final sqlite = _RacingSqliteStorage(sqlite3.openInMemory());
        addTearDown(sqlite.close);
        storage = sqlite;
      }
      final handler = SyncServer(
        storage: storage,
        settings: const ServerSettings(openRegistration: true),
      ).handler;
      final registrations = [_registration('alice'), _registration('alice')];

      final replies = await Future.wait([
        for (final request in registrations)
          _post(handler, '/v1/register', request.toJson()),
      ]);

      expect(replies.map((reply) => reply.status).toList()..sort(), [200, 409]);
      expect(
        replies.singleWhere((reply) => reply.status == 409).body['error'],
        'account_exists',
      );

      final winner = replies.indexWhere((reply) => reply.status == 200);
      final initialToken = replies[winner].body['token'] as String;
      expect(await storage.usernameForToken(initialToken), 'alice');
      for (var i = 0; i < registrations.length; i++) {
        final login = await _post(
          handler,
          '/v1/login',
          LoginRequest(
            username: 'alice',
            authVerifier: registrations[i].authVerifier,
          ).toJson(),
        );
        expect(login.status, i == winner ? 200 : 401);
      }
    });

    test('registration clears orphaned state with $backend', () async {
      late final Storage storage;
      if (backend == 'in-memory') {
        storage = InMemoryStorage();
      } else {
        final sqlite = SqliteStorage(sqlite3.openInMemory());
        addTearDown(sqlite.close);
        storage = sqlite;
      }
      final oldToken = await _seedOwnedState(storage, 'alice', 'orphan');

      final result = await storage.registerAccount(_account('alice', 'new'));

      expect(result, isA<AccountRegistered>());
      expect(await storage.usernameForToken(oldToken), isNull);
      expect(await storage.latestSeq('alice'), 0);
      expect(await storage.getRecord('alice', 'record-orphan'), isNull);
      expect(await storage.getInboxApp('app-orphan'), isNull);
      expect(await storage.listInboxApps('alice'), isEmpty);
      expect(await storage.inboxItemsSince('alice', 0), isEmpty);
    });

    test(
      'registration conflict preserves existing state with $backend',
      () async {
        late final Storage storage;
        if (backend == 'in-memory') {
          storage = InMemoryStorage();
        } else {
          final sqlite = SqliteStorage(sqlite3.openInMemory());
          addTearDown(sqlite.close);
          storage = sqlite;
        }
        final existing = _account('alice', 'existing');
        await storage.createAccount(existing);
        final token = await _seedOwnedState(storage, 'alice', 'existing');

        final result = await storage.registerAccount(_account('alice', 'new'));

        expect(result, isA<AccountAlreadyExists>());
        expect(
          (await storage.getAccount('alice'))?.authVerifierHash,
          existing.authVerifierHash,
        );
        expect(await storage.usernameForToken(token), 'alice');
        expect(await storage.latestSeq('alice'), 1);
        expect(await storage.getRecord('alice', 'record-existing'), isNotNull);
        expect(await storage.getInboxApp('app-existing'), isNotNull);
        expect(await storage.listInboxApps('alice'), hasLength(1));
        expect(await storage.inboxItemsSince('alice', 0), hasLength(1));
      },
    );
  }

  test('failed initial token insert rolls back account creation', () async {
    final database = sqlite3.openInMemory();
    final storage = SqliteStorage(database);
    addTearDown(storage.close);
    database.execute('''
      CREATE TRIGGER fail_initial_token BEFORE INSERT ON tokens
      BEGIN SELECT RAISE(ABORT, 'injected token failure'); END;
    ''');
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(openRegistration: true),
    ).handler;

    final reply = await _post(
      handler,
      '/v1/register',
      _registration('alice').toJson(),
    );

    expect(reply.status, 500);
    expect(reply.body['error'], 'internal_error');
    expect(await storage.getAccount('alice'), isNull);
    expect(
      database.select('SELECT COUNT(*) AS count FROM seqs WHERE username = ?', [
        'alice',
      ]).single['count'],
      0,
    );
  });
}

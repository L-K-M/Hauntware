import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

Account _account(String username, [String generation = 'generation']) =>
    Account(
      username: username,
      generation: generation,
      authVerifierHash: 'hash',
      verifierSalt: 'salt',
      argonSalt: 'argon',
      argonParams: const Argon2Params(),
    );

Future<String> _issue(
  Storage storage,
  Account account,
  String id,
  int now, {
  int max = 3,
}) async => (await storage.createTokenFor(
  account,
  issuedAt: now,
  expiresAt: now + 36000000,
  maxSessions: max,
  device: SessionDevice(id: id, name: 'Device $id'),
))!;

Future<AuthPrincipal> _principal(
  Storage storage,
  String token,
  int now,
) async => (await storage.principalForToken(token, now: now))!;

class _PausingAuthStorage extends InMemoryStorage {
  bool pause = false;
  final authenticated = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<AuthPrincipal?> principalForToken(
    String token, {
    required int now,
  }) async {
    final principal = await super.principalForToken(token, now: now);
    if (pause) {
      authenticated.complete();
      await resume.future;
    }
    return principal;
  }
}

class _LookupSpyStorage extends InMemoryStorage {
  var lookups = 0;

  @override
  Future<AuthPrincipal?> principalForToken(
    String token, {
    required int now,
  }) async {
    lookups++;
    return null;
  }
}

Future<Response> _request(
  Handler handler,
  String method,
  String path, {
  String? token,
  Map<String, String> headers = const {},
  Object? body,
}) async => await handler(
  Request(
    method,
    Uri.parse('http://localhost$path'),
    headers: {
      'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
      ...headers,
    },
    body: body == null ? null : jsonEncode(body),
  ),
);

Future<String> _register(
  Handler handler, {
  String username = 'alice',
  Map<String, String> headers = const {},
}) async {
  final response = await _request(
    handler,
    'POST',
    '/v1/register',
    headers: headers,
    body: RegisterRequest(
      username: username,
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params(),
      vaultKeyCheck: base64.encode(secureRandomBytes(64)),
    ).toJson(),
  );
  expect(response.statusCode, 200);
  return (jsonDecode(await response.readAsString()) as Map)['token'] as String;
}

void main() {
  test(
    'malformed or oversized bearer tokens never reach storage lookup',
    () async {
      final storage = _LookupSpyStorage();
      final handler = SyncServer(
        storage: storage,
        settings: const ServerSettings(),
      ).handler;
      final canonical = base64Url.encode(List<int>.filled(32, 255));
      for (final token in [
        '',
        'x' * 4096,
        canonical.substring(0, 43),
        '$canonical=',
        canonical.replaceAll('_', '/'),
        '!${canonical.substring(1)}',
      ]) {
        expect(
          (await _request(
            handler,
            'GET',
            '/v1/sessions',
            token: token,
          )).statusCode,
          401,
        );
        expect(storage.lookups, 0);
      }
      expect(
        (await _request(
          handler,
          'GET',
          '/v1/sessions',
          token: canonical,
        )).statusCode,
        401,
      );
      expect(storage.lookups, 1);
    },
  );
  for (final backend in <String, Storage Function()>{
    'memory': InMemoryStorage.new,
    'SQLite': () => SqliteStorage.open(':memory:'),
  }.entries) {
    test('${backend.key} lists public device session metadata', () async {
      final storage = backend.value();
      if (storage is SqliteStorage) addTearDown(storage.close);
      final handler = SyncServer(
        storage: storage,
        settings: const ServerSettings(openRegistration: true),
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      ).handler;
      final token = await _register(
        handler,
        headers: {
          'x-seance-device-id': 'device-one',
          'x-seance-device-name': 'First laptop',
        },
      );

      final response = await _request(
        handler,
        'GET',
        '/v1/sessions',
        token: token,
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final session = (body['sessions'] as List).single as Map;
      expect(session.keys.toSet(), {
        'id',
        'deviceId',
        'deviceName',
        'createdAt',
        'expiresAt',
        'lastUsedAt',
        'legacy',
        'current',
      });
      expect(session['id'], isNotEmpty);
      expect(session['id'], isNot(token));
      expect(session['id'], isNot(digestBearerToken(token)));
      expect(session['deviceId'], 'device-one');
      expect(session['deviceName'], 'First laptop');
      expect(session['createdAt'], 1000);
      expect(session['lastUsedAt'], 1000);
      expect(session['legacy'], isFalse);
      expect(session['current'], isTrue);
    });

    test(
      '${backend.key} rotates one device and caps least recently used sessions',
      () async {
        final storage = backend.value();
        if (storage is SqliteStorage) addTearDown(storage.close);
        final account = _account('alice');
        await storage.createAccount(account);
        final first = await _issue(storage, account, 'a', 1000, max: 2);
        final second = await _issue(storage, account, 'b', 2000, max: 2);
        final rotated = await _issue(storage, account, 'a', 3000, max: 2);
        expect(await storage.principalForToken(first, now: 3000), isNull);
        final principal = await _principal(storage, second, 3602000);
        final sessions = await storage.listSessionsFor(principal, now: 3602000);
        expect(sessions.first.deviceId, 'b');
        expect(sessions.first.lastUsedAt, 3602000);
        expect(
          sessions.first.expiresAt,
          36002000,
          reason: 'touch must not extend expiry',
        );
        await _issue(storage, account, 'c', 3603000, max: 2);
        expect(await storage.principalForToken(rotated, now: 3603000), isNull);
        expect(
          await storage.principalForToken(second, now: 3603000),
          isNotNull,
        );
        expect(
          await storage.listSessionsFor(principal, now: 3603000),
          hasLength(2),
        );
      },
    );

    test(
      '${backend.key} scopes selective revocation and rejects stale callers',
      () async {
        final storage = backend.value();
        if (storage is SqliteStorage) addTearDown(storage.close);
        final alice = _account('alice');
        final bob = _account('bob');
        await storage.createAccount(alice);
        await storage.createAccount(bob);
        final a = await _issue(storage, alice, 'a', 1000);
        final b = await _issue(storage, alice, 'b', 1000);
        final foreign = await _issue(storage, bob, 'foreign', 1000);
        final principalA = await _principal(storage, a, 1000);
        final principalB = await _principal(storage, b, 1000);
        final foreignPrincipal = await _principal(storage, foreign, 1000);
        final foreignId = (await storage.listSessionsFor(
          foreignPrincipal,
          now: 1000,
        )).single.id;
        expect(
          (await storage.revokeSessionByIdFor(
            principalA,
            foreignId,
            now: 1000,
          )).revoked,
          isFalse,
        );
        expect(await storage.principalForToken(foreign, now: 1000), isNotNull);
        final own = await storage.listSessionsFor(principalA, now: 1000);
        final idB = own.singleWhere((session) => session.deviceId == 'b').id;
        final result = await storage.revokeSessionByIdFor(
          principalA,
          idB,
          now: 1000,
        );
        expect(result.revoked, isTrue);
        expect(result.current, isFalse);
        await expectLater(
          storage.listSessionsFor(principalB, now: 1000),
          throwsA(isA<StalePrincipalException>()),
        );
        final idA = own.singleWhere((session) => session.current).id;
        await expectLater(
          storage.revokeSessionByIdFor(principalB, idA, now: 1000),
          throwsA(isA<StalePrincipalException>()),
        );
        final self = await storage.revokeSessionByIdFor(
          principalA,
          idA,
          now: 1000,
        );
        expect(self.revoked, isTrue);
        expect(self.current, isTrue);
      },
    );

    test(
      '${backend.key} replaced accounts and expired callers cannot inspect or revoke',
      () async {
        final storage = backend.value();
        if (storage is SqliteStorage) addTearDown(storage.close);
        final old = _account('alice', 'old');
        await storage.createAccount(old);
        final oldToken = await _issue(storage, old, 'a', 1000);
        final oldPrincipal = await _principal(storage, oldToken, 1000);
        await storage.deleteAccount('alice');
        final replacement = _account('alice', 'replacement');
        await storage.createAccount(replacement);
        final newToken = await _issue(storage, replacement, 'a', 2000);
        final current = await _principal(storage, newToken, 2000);
        final id = (await storage.listSessionsFor(
          current,
          now: 2000,
        )).single.id;
        for (final stale in [oldPrincipal, current]) {
          final now = identical(stale, current) ? 36002000 : 2000;
          await expectLater(
            storage.listSessionsFor(stale, now: now),
            throwsA(isA<StalePrincipalException>()),
          );
          await expectLater(
            storage.revokeSessionByIdFor(stale, id, now: now),
            throwsA(isA<StalePrincipalException>()),
          );
        }
        expect(await storage.principalForToken(newToken, now: 2000), isNotNull);
      },
    );

    test(
      '${backend.key} optional metadata remains compatible and supplied headers are bounded',
      () async {
        final storage = backend.value();
        if (storage is SqliteStorage) addTearDown(storage.close);
        final handler = SyncServer(
          storage: storage,
          settings: const ServerSettings(openRegistration: true),
          now: () => DateTime.fromMillisecondsSinceEpoch(1000),
        ).handler;
        final token = await _register(handler);
        final principal = await _principal(storage, token, 1000);
        final legacy = (await storage.listSessionsFor(
          principal,
          now: 1000,
        )).single;
        expect(legacy.legacy, isTrue);
        expect(legacy.deviceId, isNull);
        for (final headers in [
          {'x-seance-device-id': 'only-id'},
          {'x-seance-device-name': 'only-name'},
          {'x-seance-device-id': 'has space', 'x-seance-device-name': 'Name'},
          {'x-seance-device-id': 'id', 'x-seance-device-name': ' bad '},
          {'x-seance-device-id': 'id', 'x-seance-device-name': 'Name\u000a'},
          {'x-seance-device-id': 'id', 'x-seance-device-name': 'Name\u200d'},
          {'x-seance-device-id': 'id', 'x-seance-device-name': 'é' * 65},
          {'x-seance-device-id': 'id', 'x-seance-device-name': 'x' * 129},
          {'x-seance-device-id': 'x' * 129, 'x-seance-device-name': 'Name'},
        ]) {
          final response = await _request(
            handler,
            'POST',
            '/v1/login',
            headers: headers,
            body: const LoginRequest(
              username: 'alice',
              authVerifier: 'anything',
            ).toJson(),
          );
          expect(response.statusCode, 400);
          expect(
            jsonDecode(await response.readAsString())['error'],
            'bad_device',
          );
        }
      },
    );
  }

  for (final method in ['GET', 'DELETE']) {
    for (final replace in [false, true]) {
      test(
        '$method session request revalidates after ${replace ? 'account replacement' : 'caller revocation'}',
        () async {
          final storage = _PausingAuthStorage();
          final account = _account('alice', 'old');
          await storage.createAccount(account);
          final token = await _issue(storage, account, 'a', 1000);
          final principal = await _principal(storage, token, 1000);
          final id = (await storage.listSessionsFor(
            principal,
            now: 1000,
          )).single.id;
          storage.pause = true;
          final handler = SyncServer(
            storage: storage,
            settings: const ServerSettings(),
            now: () => DateTime.fromMillisecondsSinceEpoch(1000),
          ).handler;
          final response = _request(
            handler,
            method,
            method == 'GET' ? '/v1/sessions' : '/v1/sessions/$id',
            token: token,
          );
          await storage.authenticated.future;
          if (replace) {
            await storage.deleteAccount('alice');
            await storage.createAccount(_account('alice', 'replacement'));
          } else {
            await storage.revokeSession(principal);
          }
          storage.resume.complete();
          expect((await response).statusCode, 401);
        },
      );
    }
  }

  test(
    'SQLite adds opaque metadata to existing hashed sessions idempotently',
    () async {
      final dir = Directory.systemTemp.createTempSync('session-metadata-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/sync.sqlite';
      final db = sqlite3.open(path);
      db.execute('''
      CREATE TABLE tokens(token_digest TEXT PRIMARY KEY, username TEXT NOT NULL,
        account_generation TEXT NOT NULL, issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
    ''');
      final token = base64Url.encode(secureRandomBytes(32));
      db.execute('INSERT INTO tokens VALUES (?, ?, ?, ?, ?)', [
        digestBearerToken(token),
        'alice',
        'generation',
        1000,
        10000,
      ]);
      db.close();
      var storage = SqliteStorage.open(path);
      await storage.createAccount(_account('alice'));
      var principal = await _principal(storage, token, 1000);
      final before = (await storage.listSessionsFor(
        principal,
        now: 1000,
      )).single;
      expect(before.legacy, isTrue);
      expect(before.id, isNot(token));
      storage.close();
      storage = SqliteStorage.open(path);
      addTearDown(storage.close);
      principal = await _principal(storage, token, 1000);
      expect(
        (await storage.listSessionsFor(principal, now: 1000)).single.toJson(),
        before.toJson(),
      );
    },
  );
}

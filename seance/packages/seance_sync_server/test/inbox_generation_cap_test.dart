import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'server_test.dart' show registerReq;

Account _account(String generation) => Account(
  username: 'alice',
  generation: generation,
  authVerifierHash: 'hash',
  verifierSalt: base64.encode(List.filled(16, 1)),
  argonSalt: base64.encode(List.filled(16, 2)),
  argonParams: const Argon2Params(),
);
StoredInboxApp _app(String id, String token, int saltByte) {
  final salt = List.filled(16, saltByte);
  return StoredInboxApp(
    username: 'alice',
    appId: id,
    name: 'bot',
    tokenHash: VaultCrypto.hashAuthVerifier(utf8.encode(token), salt),
    tokenSalt: base64.encode(salt),
    created: 1,
  );
}

void main() {
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late Storage storage;
      late SyncServer server;
      late String token;
      setUp(() async {
        storage = sqlite ? SqliteStorage.open(':memory:') : InMemoryStorage();
        await storage.createAccount(_account('generation-a'));
        token = await storage.createToken('alice');
        server = SyncServer(storage: storage, settings: const ServerSettings());
      });
      tearDown(() {
        if (storage is SqliteStorage) (storage as SqliteStorage).close();
      });

      test('an old producer cannot deposit into a replacement app', () async {
        final id = newInboxAppId();
        final oldToken = newInboxToken();
        await storage.createInboxApp(_app(id, oldToken, 3));
        final reading = Completer<void>();
        final body = StreamController<List<int>>(
          onListen: () => reading.complete(),
        );
        final response = server.handler(
          Request(
            'POST',
            Uri.parse('http://local/v1/inbox/$id'),
            headers: {'authorization': 'Bearer $oldToken'},
            body: body.stream,
          ),
        );
        await reading.future.timeout(const Duration(seconds: 5));
        await storage.deleteInboxApp('alice', id);
        await storage.createInboxApp(_app(id, newInboxToken(), 4));
        body.add(Uint8List(64));
        await body.close();
        expect((await response).statusCode, 401);
        expect(await storage.inboxItemsSince('alice', 0), isEmpty);
      });

      test(
        'concurrent app registration cannot exceed the account cap',
        () async {
          for (var i = 0; i < 49; i++) {
            await storage.createInboxApp(
              _app(newInboxAppId(), newInboxToken(), i),
            );
          }
          Future<Response> create() async => server.handler(
            Request(
              'POST',
              Uri.parse('http://local/v1/apps'),
              headers: {'authorization': 'Bearer $token'},
              body: jsonEncode(
                CreateInboxAppRequest(
                  appId: newInboxAppId(),
                  name: 'bot',
                  token: newInboxToken(),
                ).toJson(),
              ),
            ),
          );
          final responses = await Future.wait([create(), create()]);
          expect(responses.map((r) => r.statusCode).toList()..sort(), [
            201,
            429,
          ]);
          expect(await storage.listInboxApps('alice'), hasLength(50));
        },
      );
    });
  }
  for (final sqlite in [false, true]) {
    test(
      '${sqlite ? 'SQLite' : 'memory'} registration clears legacy orphan rows',
      () async {
        final Storage storage = sqlite
            ? SqliteStorage.open(':memory:')
            : InMemoryStorage();
        addTearDown(() {
          if (storage is SqliteStorage) storage.close();
        });
        final app = _app(newInboxAppId(), newInboxToken(), 8);
        await storage.createInboxApp(app);
        await storage.addInboxItem(
          app.appId,
          'orphan-item',
          Uint8List(48),
          storedAt: 1,
          maxPending: 100,
        );
        await storage.putRecord(
          'alice',
          EncryptedRecord(
            id: 'orphan',
            updatedAt: 1,
            deviceId: 'old',
            deleted: false,
            seq: 1,
            blob: Uint8List(48),
          ),
        );
        await storage.nextSeq('alice');
        expect(
          await storage.registerAccount(
            _account('replacement'),
            issuedAt: 1,
            expiresAt: 100,
            maxSessions: 2,
          ),
          isNotNull,
        );
        expect(await storage.recordsSince('alice', 0), isEmpty);
        expect(await storage.latestSeq('alice'), 0);
        expect(await storage.listInboxApps('alice'), isEmpty);
        expect(await storage.inboxItemsSince('alice', 0), isEmpty);
      },
    );
    test(
      '${sqlite ? 'SQLite' : 'memory'} only one concurrent registration succeeds',
      () async {
        final Storage storage = sqlite
            ? SqliteStorage.open(':memory:')
            : InMemoryStorage();
        addTearDown(() {
          if (storage is SqliteStorage) storage.close();
        });
        final server = SyncServer(
          storage: storage,
          settings: const ServerSettings(openRegistration: true),
        );
        Future<Response> register() async => server.handler(
          Request(
            'POST',
            Uri.parse('http://local/v1/register'),
            body: jsonEncode(registerReq('alice').toJson()),
          ),
        );
        final responses = await Future.wait([register(), register()]);
        expect(responses.map((r) => r.statusCode).toList()..sort(), [200, 409]);
      },
    );
  }

  test(
    'SQLite rolls account creation back when its initial token fails',
    () async {
      final db = sqlite3.open(':memory:');
      final storage = SqliteStorage(db);
      addTearDown(storage.close);
      db.execute(
        "CREATE TRIGGER reject_initial_token BEFORE INSERT ON tokens BEGIN SELECT RAISE(ABORT, 'injected token failure'); END",
      );
      final server = SyncServer(
        storage: storage,
        settings: const ServerSettings(openRegistration: true),
      );
      final response = await server.handler(
        Request(
          'POST',
          Uri.parse('http://local/v1/register'),
          body: jsonEncode(registerReq('alice').toJson()),
        ),
      );
      expect(response.statusCode, 500);
      expect(await storage.getAccount('alice'), isNull);
    },
  );
}

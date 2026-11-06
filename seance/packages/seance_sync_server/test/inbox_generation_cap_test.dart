import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Account _account(String generation) => Account(
  username: 'alice', generation: generation, authVerifierHash: 'hash',
  verifierSalt: base64.encode(List.filled(16, 1)),
  argonSalt: base64.encode(List.filled(16, 2)), argonParams: const Argon2Params(),
);
StoredInboxApp _app(String id, String token, int saltByte) {
  final salt = List.filled(16, saltByte);
  return StoredInboxApp(username: 'alice', appId: id, name: 'bot',
    tokenHash: VaultCrypto.hashAuthVerifier(utf8.encode(token), salt),
    tokenSalt: base64.encode(salt), created: 1);
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
      tearDown(() { if (storage is SqliteStorage) (storage as SqliteStorage).close(); });

      test('an old producer cannot deposit into a replacement app', () async {
        final id = newInboxAppId();
        final oldToken = newInboxToken();
        await storage.createInboxApp(_app(id, oldToken, 3));
        final reading = Completer<void>();
        final body = StreamController<List<int>>(onListen: () => reading.complete());
        final response = server.handler(Request('POST', Uri.parse('http://local/v1/inbox/$id'),
          headers: {'authorization': 'Bearer $oldToken'}, body: body.stream));
        await reading.future.timeout(const Duration(seconds: 5));
        await storage.deleteInboxApp('alice', id);
        await storage.createInboxApp(_app(id, newInboxToken(), 4));
        body.add(Uint8List(64));
        await body.close();
        expect((await response).statusCode, 401);
        expect(await storage.inboxItemsSince('alice', 0), isEmpty);
      });

      test('concurrent app registration cannot exceed the account cap', () async {
        for (var i = 0; i < 49; i++) {
          await storage.createInboxApp(_app(newInboxAppId(), newInboxToken(), i));
        }
        Future<Response> create() async => server.handler(Request('POST', Uri.parse('http://local/v1/apps'),
          headers: {'authorization': 'Bearer $token'},
          body: jsonEncode(CreateInboxAppRequest(appId: newInboxAppId(), name: 'bot', token: newInboxToken()).toJson())));
        final responses = await Future.wait([create(), create()]);
        expect(responses.map((r) => r.statusCode).toList()..sort(), [201, 429]);
        expect(await storage.listInboxApps('alice'), hasLength(50));
      });
    });
  }
}

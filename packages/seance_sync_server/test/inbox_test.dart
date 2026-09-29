import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// The command inbox endpoints (docs/INBOX.md), driven through the shelf
/// handler against both storage backends.
void main() {
  for (final backend in <String, Storage Function()>{
    'in-memory': InMemoryStorage.new,
    'SQLite': () => SqliteStorage.open(':memory:'),
  }.entries) {
    group('${backend.key} storage', () => _inboxTests(backend.value));
  }
}

class _Reply {
  final int status;
  final String text;
  final String? contentType;
  _Reply(this.status, this.text, this.contentType);

  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
  String? get code => json['error'] as String?;
}

class _App {
  final String id;
  final String token;
  _App(this.id, this.token);
}

class _Harness {
  late final Handler handler;
  DateTime now = DateTime.utc(2026, 9, 29, 12);

  _Harness(Storage storage, {RateLimiter? inboxLimiter}) {
    handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(openRegistration: true),
      inboxLimiter: inboxLimiter,
      now: () => now,
    ).handler;
  }

  Future<_Reply> send(
    String method,
    String path, {
    String? bearer,
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final res = await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          if (bearer != null) 'authorization': 'Bearer $bearer',
          ...headers,
        },
        body: body,
      ),
    );
    return _Reply(
      res.statusCode,
      await res.readAsString(),
      res.headers['content-type'],
    );
  }

  Future<String> register(String user) async {
    final r = await send(
      'POST',
      '/v1/register',
      body: jsonEncode(
        RegisterRequest(
          username: user,
          authVerifier: base64.encode(secureRandomBytes(32)),
          argonSalt: base64.encode(secureRandomBytes(16)),
          argonParams: const Argon2Params(),
        ).toJson(),
      ),
    );
    expect(r.status, 200, reason: r.text);
    return r.json['token'] as String;
  }

  Future<_Reply> createApp(
    String session, {
    String? appId,
    String? token,
    String name = 'Dev VM agent',
  }) => send(
    'POST',
    '/v1/apps',
    bearer: session,
    body: jsonEncode({
      'app': appId ?? newInboxAppId(),
      'name': name,
      'token': token ?? newInboxToken(),
    }),
  );

  Future<_App> app(String session) async {
    final app = _App(newInboxAppId(), newInboxToken());
    final r = await createApp(session, appId: app.id, token: app.token);
    expect(r.status, 201, reason: r.text);
    return app;
  }

  Future<_Reply> deposit(String appId, String? token, List<int> blob) => send(
    'POST',
    '/v1/inbox/$appId',
    bearer: token,
    body: blob,
    headers: {'content-type': 'application/octet-stream'},
  );

  Future<List<InboxItem>> items(String session, {int since = 0}) async {
    final r = await send('GET', '/v1/inbox?since=$since', bearer: session);
    expect(r.status, 200, reason: r.text);
    return [
      for (final item in r.json['items'] as List)
        InboxItem.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<InboxAppInfo>> apps(String session) async {
    final r = await send('GET', '/v1/apps', bearer: session);
    expect(r.status, 200, reason: r.text);
    return [
      for (final app in r.json['apps'] as List)
        InboxAppInfo.fromJson(app as Map<String, dynamic>),
    ];
  }
}

Uint8List _blob([int length = 64]) => secureRandomBytes(length);

void _inboxTests(Storage Function() newStorage) {
  late _Harness h;
  late String alice;

  setUp(() async {
    h = _Harness(newStorage(), inboxLimiter: RateLimiter(maxAttempts: 1000));
    alice = await h.register('alice');
  });

  group('apps', () {
    test('create, list and delete', () async {
      final appId = newInboxAppId();
      final created = await h.createApp(
        alice,
        appId: appId,
        name: '  Dev VM agent  ',
      );
      expect(created.status, 201);
      expect(created.json, isEmpty);

      final apps = await h.apps(alice);
      expect(apps, hasLength(1));
      expect(apps.single.appId, appId);
      expect(apps.single.name, 'Dev VM agent');
      expect(apps.single.created, h.now.millisecondsSinceEpoch);
      expect(apps.single.pending, 0);

      expect(
        (await h.send('DELETE', '/v1/apps/$appId', bearer: alice)).status,
        204,
      );
      expect(await h.apps(alice), isEmpty);
      final again = await h.send('DELETE', '/v1/apps/$appId', bearer: alice);
      expect(again.status, 404);
      expect(again.code, 'not_found');
    });

    test('a taken app id is a 409 in any account', () async {
      final appId = newInboxAppId();
      expect((await h.createApp(alice, appId: appId)).status, 201);
      final dup = await h.createApp(alice, appId: appId);
      expect(dup.status, 409);
      expect(dup.code, 'app_exists');

      // Ids are global because the producer endpoint names only the app.
      final bob = await h.register('bob');
      expect((await h.createApp(bob, appId: appId)).code, 'app_exists');
      expect(await h.apps(bob), isEmpty);
    });

    test('malformed ids, tokens and names are 400', () async {
      final cases = <String, _Reply>{
        'short id': await h.createApp(alice, appId: 'abc'),
        'id with padding': await h.createApp(
          alice,
          appId: '${newInboxAppId().substring(1)}=',
        ),
        'short token': await h.createApp(alice, token: 'abc'),
        'empty name': await h.createApp(alice, name: ''),
        'blank name': await h.createApp(alice, name: '   '),
        'long name': await h.createApp(
          alice,
          name: 'x' * (kInboxMaxNameChars + 1),
        ),
        'control character': await h.createApp(alice, name: 'bad\u202ename'),
        'not JSON': await h.send(
          'POST',
          '/v1/apps',
          bearer: alice,
          body: 'nope',
        ),
        'missing token': await h.send(
          'POST',
          '/v1/apps',
          bearer: alice,
          body: jsonEncode({'app': newInboxAppId(), 'name': 'x'}),
        ),
      };
      for (final c in cases.entries) {
        expect(c.value.status, 400, reason: c.key);
        expect(c.value.code, 'bad_request', reason: c.key);
      }
      expect(await h.apps(alice), isEmpty);
      expect(
        (await h.createApp(alice, name: 'x' * kInboxMaxNameChars)).status,
        201,
      );
    });

    test('app routes need a session', () async {
      expect((await h.send('GET', '/v1/apps')).status, 401);
      expect((await h.createApp('not-a-session')).status, 401);
    });

    test('another account can neither see nor delete an app', () async {
      final app = await h.app(alice);
      final bob = await h.register('bob');
      expect(await h.apps(bob), isEmpty);
      final r = await h.send('DELETE', '/v1/apps/${app.id}', bearer: bob);
      expect(r.status, 404);
      expect(await h.apps(alice), hasLength(1));
    });
  });

  group('deposits', () {
    test('a sealed proposal is queued and listed', () async {
      final key = newInboxKey();
      final app = await h.app(alice);
      final plain = utf8.encode('{"v":1}');
      final blob = await InboxCrypto.seal(key, app.id, plain);

      final r = await h.deposit(app.id, app.token, blob);
      expect(r.status, 201, reason: r.text);
      final itemId = r.json['item'] as String;
      expect(itemId, isNotEmpty);

      final items = await h.items(alice);
      expect(items, hasLength(1));
      expect(items.single.appId, app.id);
      expect(items.single.itemId, itemId);
      expect(items.single.received, 1);
      expect(await InboxCrypto.open(key, app.id, items.single.blob), plain);
      expect((await h.apps(alice)).single.pending, 1);
    });

    test('unknown app and wrong token are the same 401', () async {
      final app = await h.app(alice);
      final replies = [
        await h.deposit(app.id, newInboxToken(), _blob()),
        await h.deposit(newInboxAppId(), app.token, _blob()),
        await h.deposit('not-an-app-id', app.token, _blob()),
        await h.deposit(app.id, null, _blob()),
        await h.deposit(app.id, alice, _blob()),
      ];
      for (final r in replies) {
        expect(r.status, 401);
        expect(r.text, replies.first.text);
      }
      expect(replies.first.code, 'unauthorized');
      expect(await h.items(alice), isEmpty);
    });

    test('the deposit token cannot list, read or delete', () async {
      final app = await h.app(alice);
      final itemId =
          (await h.deposit(app.id, app.token, _blob())).json['item'] as String;
      for (final (method, path) in [
        ('GET', '/v1/inbox'),
        ('GET', '/v1/apps'),
        ('DELETE', '/v1/inbox/${app.id}/$itemId'),
        ('DELETE', '/v1/apps/${app.id}'),
        ('GET', '/v1/sync'),
      ]) {
        final r = await h.send(method, path, bearer: app.token);
        expect(r.status, 401, reason: '$method $path');
      }
      expect(await h.items(alice), hasLength(1));
    });

    test('size limits: 413 above the cap, 400 below a sealed box', () async {
      final app = await h.app(alice);
      expect(
        (await h.deposit(app.id, app.token, _blob(kInboxMaxBlobBytes))).status,
        201,
      );
      final big = await h.deposit(
        app.id,
        app.token,
        _blob(kInboxMaxBlobBytes + 1),
      );
      expect(big.status, 413);
      expect(big.code, 'payload_too_large');

      // Without a Content-Length the cap still holds while streaming.
      final streamed = await h.send(
        'POST',
        '/v1/inbox/${app.id}',
        bearer: app.token,
        body: Stream.value(_blob(kInboxMaxBlobBytes + 1)),
      );
      expect(streamed.status, 413);

      final small = await h.deposit(app.id, app.token, _blob(39));
      expect(small.status, 400);
      expect(small.code, 'bad_request');
      expect((await h.deposit(app.id, app.token, _blob(40))).status, 201);
      expect(await h.items(alice), hasLength(2));
    });

    test('an app holds at most 100 pending items', () async {
      final app = await h.app(alice);
      for (var i = 0; i < 100; i++) {
        expect((await h.deposit(app.id, app.token, _blob())).status, 201);
      }
      final full = await h.deposit(app.id, app.token, _blob());
      expect(full.status, 429);
      expect(full.code, 'inbox_full');

      // Another app of the same account has its own allowance.
      final other = await h.app(alice);
      expect((await h.deposit(other.id, other.token, _blob())).status, 201);

      final first = (await h.items(alice)).first;
      await h.send(
        'DELETE',
        '/v1/inbox/${first.appId}/${first.itemId}',
        bearer: alice,
      );
      expect((await h.deposit(app.id, app.token, _blob())).status, 201);
    });

    test('deposits are rate limited per app, after the token check', () async {
      h = _Harness(newStorage());
      alice = await h.register('alice');
      final app = await h.app(alice);
      final other = await h.app(alice);

      // Strangers cannot spend the app's budget.
      for (var i = 0; i < 40; i++) {
        await h.deposit(app.id, newInboxToken(), _blob());
      }
      for (var i = 0; i < 30; i++) {
        expect((await h.deposit(app.id, app.token, _blob())).status, 201);
      }
      final limited = await h.deposit(app.id, app.token, _blob());
      expect(limited.status, 429);
      expect(limited.code, 'rate_limited');
      expect((await h.deposit(other.id, other.token, _blob())).status, 201);

      h.now = h.now.add(const Duration(minutes: 1, seconds: 1));
      expect((await h.deposit(app.id, app.token, _blob())).status, 201);
    });
  });

  group('the user side', () {
    test('since returns only newer items, in received order', () async {
      final a = await h.app(alice);
      final b = await h.app(alice);
      for (final app in [a, b, a]) {
        expect((await h.deposit(app.id, app.token, _blob())).status, 201);
      }
      final all = await h.items(alice);
      expect(all.map((i) => i.received), [1, 2, 3]);
      expect(all.map((i) => i.appId), [a.id, b.id, a.id]);
      expect((await h.items(alice, since: 1)).map((i) => i.received), [2, 3]);
      expect(await h.items(alice, since: 3), isEmpty);

      // `received` keeps rising after items and apps are gone, so a device
      // that already saw 3 still learns about the next one.
      await h.send('DELETE', '/v1/apps/${a.id}', bearer: alice);
      await h.deposit(b.id, b.token, _blob());
      expect((await h.items(alice, since: 3)).single.received, 4);
    });

    test('items are per account', () async {
      final app = await h.app(alice);
      await h.deposit(app.id, app.token, _blob());
      final bob = await h.register('bob');
      expect(await h.items(bob), isEmpty);
      final item = (await h.items(alice)).single;
      final r = await h.send(
        'DELETE',
        '/v1/inbox/${app.id}/${item.itemId}',
        bearer: bob,
      );
      expect(r.status, 404);
      expect(await h.items(alice), hasLength(1));
    });

    test('a second delete is a 404: the claim was lost', () async {
      final app = await h.app(alice);
      final itemId =
          (await h.deposit(app.id, app.token, _blob())).json['item'] as String;
      final path = '/v1/inbox/${app.id}/$itemId';
      final first = await h.send('DELETE', path, bearer: alice);
      expect(first.status, 204);
      expect(first.text, isEmpty);
      final second = await h.send('DELETE', path, bearer: alice);
      expect(second.status, 404);
      expect(second.code, 'not_found');
      expect(await h.items(alice), isEmpty);
    });

    test('removing an app drops its items and its token', () async {
      final app = await h.app(alice);
      final kept = await h.app(alice);
      await h.deposit(app.id, app.token, _blob());
      await h.deposit(kept.id, kept.token, _blob());
      await h.send('DELETE', '/v1/apps/${app.id}', bearer: alice);

      expect((await h.items(alice)).single.appId, kept.id);
      expect((await h.deposit(app.id, app.token, _blob())).status, 401);
    });

    test('deleting the account drops its apps and items', () async {
      final app = await h.app(alice);
      await h.deposit(app.id, app.token, _blob());
      expect(
        (await h.send('DELETE', '/v1/account', bearer: alice)).status,
        200,
      );

      expect((await h.deposit(app.id, app.token, _blob())).status, 401);
      final again = await h.register('alice');
      expect(await h.apps(again), isEmpty);
      expect(await h.items(again), isEmpty);
      // The id is free again.
      expect((await h.createApp(again, appId: app.id)).status, 201);
    });

    test('items expire seven days after they were received', () async {
      final app = await h.app(alice);
      await h.deposit(app.id, app.token, _blob());
      h.now = h.now.add(const Duration(days: 1));
      await h.deposit(app.id, app.token, _blob());

      h.now = h.now.add(
        kInboxRetention - const Duration(days: 1, milliseconds: 1),
      );
      expect(await h.items(alice), hasLength(2));
      h.now = h.now.add(const Duration(milliseconds: 1));
      expect((await h.items(alice)).single.received, 2);
      expect((await h.apps(alice)).single.pending, 1);
      h.now = h.now.add(const Duration(days: 1));
      expect(await h.items(alice), isEmpty);
    });
  });

  group('producer documentation', () {
    test('is served without auth with the right types', () async {
      final llms = await h.send('GET', '/llms.txt');
      expect(llms.status, 200);
      expect(llms.contentType, startsWith('text/plain'));
      expect(llms.text, contains(kInboxPairingPrefix));
      expect(llms.text, contains('seance/v1/inbox/'));
      expect(llms.text, contains('crypto_aead_xchacha20poly1305_ietf_encrypt'));

      final openapi = await h.send('GET', '/v1/inbox/openapi.json');
      expect(openapi.status, 200);
      expect(openapi.contentType, startsWith('application/json'));
      expect(openapi.json['openapi'], '3.1.0');
      expect((openapi.json['paths'] as Map).keys, ['/v1/inbox/{appId}']);

      final py = await h.send('GET', '/v1/inbox/seance-propose.py');
      expect(py.status, 200);
      expect(py.contentType, startsWith('text/x-python'));
      expect(py.text, startsWith('#!/usr/bin/env python3'));
      // Séance hands agents this hash so they can check the download; a
      // client edited without updating it would fail every check.
      expect(
        sha256.convert(utf8.encode(py.text)).toString(),
        kInboxReferenceClientSha256,
      );

      final landing = await h.send('GET', '/');
      expect(landing.text, contains('/llms.txt'));
    });

    test('states the limits the server enforces', () async {
      final llms = (await h.send('GET', '/llms.txt')).text;
      expect(llms, contains('96 KiB'));
      expect(llms, contains('$kInboxMaxTitleChars characters'));
      expect(llms, contains('$kInboxMaxReasonChars characters'));
      final py = (await h.send('GET', '/v1/inbox/seance-propose.py')).text;
      expect(
        py,
        contains('MAX_BLOB_BYTES = ${kInboxMaxBlobBytes ~/ 1024} * 1024'),
      );
      expect(py, contains('MAX_TITLE_CHARS = $kInboxMaxTitleChars'));
      expect(py, contains('MAX_REASON_CHARS = $kInboxMaxReasonChars'));
      expect(
        py,
        contains('MAX_SCRIPT_BYTES = ${kInboxMaxScriptBytes ~/ 1024} * 1024'),
      );
    });
  });
}

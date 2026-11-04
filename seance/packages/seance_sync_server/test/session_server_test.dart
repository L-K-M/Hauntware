import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _Reply {
  final int status;
  final Map<String, dynamic> body;

  const _Reply(this.status, this.body);
}

class _Harness {
  final InMemoryStorage storage = InMemoryStorage();
  late final Handler handler;
  DateTime now = DateTime.utc(2026, 1, 1);

  _Harness({Duration ttl = const Duration(days: 90), int maxSessions = 32}) {
    handler = SyncServer(
      storage: storage,
      settings: ServerSettings(
        openRegistration: true,
        sessionTtl: ttl,
        maxSessionsPerAccount: maxSessions,
      ),
      now: () => now,
    ).handler;
  }

  Future<_Reply> send(
    String method,
    String path, {
    Object? body,
    String? bearer,
    String? deviceId,
    String? deviceName,
  }) async {
    final response = await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          'content-type': 'application/json',
          if (bearer != null) 'authorization': 'Bearer $bearer',
          if (deviceId != null) 'x-seance-device-id': deviceId,
          if (deviceName != null) 'x-seance-device-name': deviceName,
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await response.readAsString();
    return _Reply(
      response.statusCode,
      text.isEmpty ? const {} : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<({String token, String verifier})> register(
    String username,
    String deviceId, {
    String? verifier,
  }) async {
    final authVerifier = verifier ?? base64.encode(secureRandomBytes(32));
    final response = await send(
      'POST',
      '/v1/register',
      deviceId: deviceId,
      deviceName: 'Device $deviceId',
      body: RegisterRequest(
        username: username,
        authVerifier: authVerifier,
        argonSalt: base64.encode(secureRandomBytes(16)),
        argonParams: const Argon2Params(),
      ).toJson(),
    );
    expect(response.status, 200, reason: response.body.toString());
    return (token: response.body['token'] as String, verifier: authVerifier);
  }

  Future<String> login(
    String username,
    String verifier,
    String deviceId,
  ) async {
    final response = await send(
      'POST',
      '/v1/login',
      deviceId: deviceId,
      deviceName: 'Device $deviceId',
      body: LoginRequest(username: username, authVerifier: verifier).toJson(),
    );
    expect(response.status, 200, reason: response.body.toString());
    return response.body['token'] as String;
  }
}

void main() {
  test('register and login require strict bounded device headers', () async {
    final h = _Harness();
    final request = RegisterRequest(
      username: 'alice',
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params(),
    ).toJson();

    for (final values in <(String?, String?)>[
      (null, null),
      ('', 'name'),
      (' has-space', 'name'),
      ('device', ' name'),
      ('device', 'bad\u0000name'),
      ('x' * 129, 'name'),
      ('device', 'x' * 129),
    ]) {
      final response = await h.send(
        'POST',
        '/v1/register',
        deviceId: values.$1,
        deviceName: values.$2,
        body: request,
      );
      expect(response.status, 400, reason: values.toString());
      expect(response.body['error'], 'bad_device', reason: values.toString());
    }
    expect(await h.storage.getAccount('alice'), isNull);
  });

  test('same-device login rotates its bearer and keeps one session', () async {
    final h = _Harness();
    final registered = await h.register('alice', 'mac');
    h.now = h.now.add(const Duration(minutes: 1));
    final replacement = await h.login('alice', registered.verifier, 'mac');
    expect(replacement, isNot(registered.token));

    expect(
      (await h.send('GET', '/v1/sessions', bearer: registered.token)).status,
      401,
    );
    final listed = await h.send('GET', '/v1/sessions', bearer: replacement);
    expect(listed.status, 200);
    final sessions = listed.body['sessions'] as List;
    expect(sessions, hasLength(1));
    expect((sessions.single as Map)['deviceId'], 'mac');
    expect((sessions.single as Map)['current'], isTrue);
  });

  test('session list and revocation stay account-scoped', () async {
    final h = _Harness();
    final alice = await h.register('alice', 'alice-a');
    final aliceB = await h.login('alice', alice.verifier, 'alice-b');
    final bob = await h.register('bob', 'bob-a');

    final aliceList = await h.send('GET', '/v1/sessions', bearer: alice.token);
    final aliceSessions = [
      for (final session in aliceList.body['sessions'] as List)
        SyncSessionInfo.fromJson((session as Map).cast()),
    ];
    expect(aliceSessions, hasLength(2));
    expect(
      aliceSessions.singleWhere((session) => session.current).deviceId,
      'alice-a',
    );
    final aliceBId = aliceSessions
        .singleWhere((session) => session.deviceId == 'alice-b')
        .id;

    final bobList = await h.send('GET', '/v1/sessions', bearer: bob.token);
    final bobId = ((bobList.body['sessions'] as List).single as Map)['id'];
    final refused = await h.send(
      'DELETE',
      '/v1/sessions/$bobId',
      bearer: alice.token,
    );
    expect(refused.status, 404);
    expect(
      (await h.send('GET', '/v1/sessions', bearer: bob.token)).status,
      200,
    );

    final revoked = await h.send(
      'DELETE',
      '/v1/sessions/$aliceBId',
      bearer: alice.token,
    );
    expect(revoked.status, 200);
    expect(revoked.body, {'revoked': true, 'current': false});
    expect((await h.send('GET', '/v1/sessions', bearer: aliceB)).status, 401);

    final current = await h.send(
      'DELETE',
      '/v1/sessions/current',
      bearer: alice.token,
    );
    expect(current.body, {'revoked': true, 'current': true});
    expect(
      (await h.send('GET', '/v1/sessions', bearer: alice.token)).status,
      401,
    );
  });

  test('revoke-all invalidates every bearer', () async {
    final h = _Harness();
    final first = await h.register('alice', 'one');
    final second = await h.login('alice', first.verifier, 'two');
    final response = await h.send('DELETE', '/v1/sessions', bearer: second);
    expect(response.body, {'revoked': true, 'current': true});
    expect(
      (await h.send('GET', '/v1/sessions', bearer: first.token)).status,
      401,
    );
    expect((await h.send('GET', '/v1/sessions', bearer: second)).status, 401);
  });

  test('fixed expiry rejects a bearer at the exact deadline', () async {
    final h = _Harness(ttl: const Duration(hours: 1));
    final registered = await h.register('alice', 'mac');
    h.now = h.now.add(const Duration(hours: 1));
    final response = await h.send(
      'GET',
      '/v1/sessions',
      bearer: registered.token,
    );
    expect(response.status, 401);
    expect(response.body['error'], 'unauthorized');
  });

  test('malformed bearer is rejected before storage lookup', () async {
    final h = _Harness();
    final registered = await h.register('alice', 'mac');
    for (final token in [
      'short',
      '${registered.token}x',
      registered.token.replaceAll('=', ''),
      '${registered.token.substring(0, 43)}!',
    ]) {
      final response = await h.send('GET', '/v1/sessions', bearer: token);
      expect(response.status, 401, reason: token);
    }
  });
}

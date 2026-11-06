import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'server_test.dart' show TestClient, registerReq;

void main() {
  test('a correct verifier is not locked out by account failures', () async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(openRegistration: true),
      loginLimiter: RateLimiter(maxAttempts: 1),
    );
    final c = TestClient(server.handler);
    final registration = registerReq('recoverable');
    await c.send('POST', '/v1/register', body: registration.toJson());
    final wrong = LoginRequest(
      username: 'recoverable',
      authVerifier: base64.encode(secureRandomBytes(32)),
    ).toJson();
    expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
    expect((await c.send('POST', '/v1/login', body: wrong)).$1, 429);

    final correct = LoginRequest(
      username: 'recoverable',
      authVerifier: registration.authVerifier,
    ).toJson();
    expect((await c.send('POST', '/v1/login', body: correct)).$1, 200);
  });

  test('global limiter spans routes, usernames, and sources', () async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(openRegistration: true),
      authGlobalLimiter: RateLimiter(maxAttempts: 2),
      authSourceLimiter: RateLimiter(maxAttempts: 100),
      sourceFor: (request) => request.headers['x-test-source'] ?? 'unknown',
    );
    final c = TestClient(server.handler);
    expect(
      (await c.send(
        'POST',
        '/v1/prelogin',
        body: {'username': 'one'},
        headers: {'x-test-source': 'source-a'},
      )).$1,
      404,
    );
    expect(
      (await c.send(
        'POST',
        '/v1/prelogin',
        body: {'username': 'two'},
        headers: {'x-test-source': 'source-b'},
      )).$1,
      404,
    );
    expect(
      (await c.send(
        'POST',
        '/v1/register',
        body: registerReq('three').toJson(),
        headers: {'x-test-source': 'source-c'},
      )).$1,
      429,
    );
  });

  test('source limiter spans auth routes and usernames', () async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(openRegistration: true),
      authGlobalLimiter: RateLimiter(maxAttempts: 100),
      authSourceLimiter: RateLimiter(maxAttempts: 2),
      sourceFor: (request) => request.headers['x-test-source'] ?? 'unknown',
    );
    final c = TestClient(server.handler);
    for (final username in ['one', 'two']) {
      expect(
        (await c.send(
          'POST',
          '/v1/prelogin',
          body: {'username': username},
          headers: {'x-test-source': 'same'},
        )).$1,
        404,
      );
    }
    expect(
      (await c.send(
        'POST',
        '/v1/register',
        body: registerReq('three').toJson(),
        headers: {'x-test-source': 'same'},
      )).$1,
      429,
    );
    expect(
      (await c.send(
        'POST',
        '/v1/register',
        body: registerReq('other-source').toJson(),
        headers: {'x-test-source': 'other'},
      )).$1,
      200,
    );
  });

  test('a blocked source cannot exhaust the global allowance', () async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(openRegistration: true),
      authGlobalLimiter: RateLimiter(maxAttempts: 2),
      authSourceLimiter: RateLimiter(maxAttempts: 1),
      sourceFor: (request) => request.headers['x-test-source'] ?? 'unknown',
    );
    final c = TestClient(server.handler);
    Future<int> prelogin(String source, int n) async => (await c.send(
      'POST',
      '/v1/prelogin',
      body: {'username': 'missing-$n'},
      headers: {'x-test-source': source},
    )).$1;

    expect(await prelogin('abusive', 0), 404);
    for (var i = 1; i < 20; i++) {
      expect(await prelogin('abusive', i), 429);
    }
    expect(await prelogin('fresh', 20), 404);
    expect(
      await prelogin('another', 21),
      429,
      reason: 'the two admitted sources consumed the global allowance',
    );
  });
}

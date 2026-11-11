import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'dart:io';
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

  group('forwarded source behind a proxy', () {
    // The default source resolution, fed the peer address shelf_io reports.
    Future<int> prelogin(
      SyncServer server, {
      required String peer,
      String? forwardedFor,
    }) async {
      final response = await server.handler(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/prelogin'),
          headers: {
            'content-type': 'application/json',
            'x-seance-protocol-version': '$kProtocolVersion',
            'x-forwarded-for': ?forwardedFor,
          },
          context: {'shelf.io.connection_info': _Connection(peer)},
          body: jsonEncode({'username': 'missing'}),
        ),
      );
      await response.readAsString();
      return response.statusCode;
    }

    SyncServer serverTrusting(Set<String> proxies) => SyncServer(
      storage: InMemoryStorage(),
      settings: ServerSettings(trustedProxies: proxies),
      authGlobalLimiter: RateLimiter(maxAttempts: 100),
      authSourceLimiter: RateLimiter(maxAttempts: 1),
    );

    test('a trusted proxy range gives each client its own bucket', () async {
      final server = serverTrusting({'172.16.0.0/12'});
      expect(
        await prelogin(server, peer: '172.18.0.2', forwardedFor: '203.0.113.4'),
        404,
      );
      expect(
        await prelogin(server, peer: '172.18.0.2', forwardedFor: '203.0.113.5'),
        404,
        reason: 'another client behind the same proxy is not limited',
      );
      expect(
        await prelogin(server, peer: '172.18.0.2', forwardedFor: '203.0.113.4'),
        429,
      );
    });

    test('an untrusted peer cannot pick its bucket with the header', () async {
      final server = serverTrusting({'172.16.0.0/12'});
      expect(
        await prelogin(
          server,
          peer: '198.51.100.7',
          forwardedFor: '203.0.113.4',
        ),
        404,
      );
      expect(
        await prelogin(
          server,
          peer: '198.51.100.7',
          forwardedFor: '203.0.113.5',
        ),
        429,
      );
    });

    test('without trusted proxies every client shares the proxy', () async {
      final server = serverTrusting(const {});
      expect(
        await prelogin(server, peer: '172.18.0.2', forwardedFor: '203.0.113.4'),
        404,
      );
      expect(
        await prelogin(server, peer: '172.18.0.2', forwardedFor: '203.0.113.5'),
        429,
      );
    });
  });
}

class _Connection implements HttpConnectionInfo {
  _Connection(String address) : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 40000;

  @override
  int get localPort => 8787;
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('HttpSyncClient constructor device headers', () {
    test(
      'sends x-seance-device-id and x-seance-device-name on register',
      () async {
        Map<String, String>? capturedHeaders;
        String? capturedBody;
        final client = MockClient((req) async {
          capturedHeaders = Map<String, String>.from(req.headers);
          capturedBody = req.body;
          return http.Response(
            jsonEncode({'token': 'tok', 'recordEnvelopeFloor': 2}),
            200,
          );
        });

        final sync = HttpSyncClient(
          baseUrl: 'https://host',
          client: client,
          deviceId: 'dev-1',
          deviceName: 'My Laptop',
        );

        await sync.register(
          RegisterRequest(
            username: 'alice',
            authVerifier: 'verifier',
            argonSalt: 'salt',
            argonParams: const Argon2Params.fast(),
            vaultKeyCheck: 'check',
          ),
        );

        expect(capturedHeaders!['x-seance-device-id'], 'dev-1');
        expect(capturedHeaders!['x-seance-device-name'], 'My Laptop');
        expect(capturedHeaders!.containsKey('authorization'), isFalse);
        final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
        expect(body['username'], 'alice');
        expect(body['vaultKeyCheck'], 'check');
        expect(body['protocolVersion'], kProtocolVersion);
      },
    );

    test('sends device headers on login', () async {
      Map<String, String>? capturedHeaders;
      final client = MockClient((req) async {
        capturedHeaders = Map<String, String>.from(req.headers);
        return http.Response(
          jsonEncode({
            'token': 'tok',
            'vaultKeyCheck': 'vk',
            'recordEnvelopeFloor': 2,
          }),
          200,
        );
      });

      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        deviceId: 'dev-2',
        deviceName: 'My Phone',
      );

      final response = await sync.login(
        const LoginRequest(username: 'bob', authVerifier: 'ver'),
      );

      expect(capturedHeaders!['x-seance-device-id'], 'dev-2');
      expect(capturedHeaders!['x-seance-device-name'], 'My Phone');
      expect(capturedHeaders!.containsKey('authorization'), isFalse);
      expect(response.token, 'tok');
      expect(response.vaultKeyCheck, 'vk');
      expect(sync.token, 'tok');
    });

    test(
      'omits device headers when both deviceId and deviceName are null',
      () async {
        Map<String, String>? capturedHeaders;
        final client = MockClient((req) async {
          capturedHeaders = Map<String, String>.from(req.headers);
          return http.Response(
            jsonEncode({'token': 'tok', 'recordEnvelopeFloor': 2}),
            200,
          );
        });

        final sync = HttpSyncClient(baseUrl: 'https://host', client: client);

        await sync.register(
          RegisterRequest(
            username: 'carol',
            authVerifier: 'verifier',
            argonSalt: 'salt',
            argonParams: const Argon2Params.fast(),
          ),
        );

        expect(capturedHeaders!.containsKey('x-seance-device-id'), isFalse);
        expect(capturedHeaders!.containsKey('x-seance-device-name'), isFalse);
      },
    );

    test('preserves response token and vaultKeyCheck on register', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'token': 'reg-token',
            'vaultKeyCheck': 'reg-check',
            'recordEnvelopeFloor': 2,
          }),
          200,
        );
      });

      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        deviceId: 'dev-1',
        deviceName: 'Device',
      );

      final response = await sync.register(
        RegisterRequest(
          username: 'dave',
          authVerifier: 'verifier',
          argonSalt: 'salt',
          argonParams: const Argon2Params.fast(),
          vaultKeyCheck: 'sent-check',
        ),
      );

      expect(response.token, 'reg-token');
      expect(response.vaultKeyCheck, 'reg-check');
      expect(sync.token, 'reg-token');
    });

    test('preserves response token and vaultKeyCheck on login', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'token': 'login-token',
            'vaultKeyCheck': 'login-check',
            'recordEnvelopeFloor': 2,
          }),
          200,
        );
      });

      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        deviceId: 'dev-1',
        deviceName: 'Device',
      );

      final response = await sync.login(
        const LoginRequest(username: 'eve', authVerifier: 'ver'),
      );

      expect(response.token, 'login-token');
      expect(response.vaultKeyCheck, 'login-check');
      expect(sync.token, 'login-token');
    });
  });

  group('HttpSyncClient listSessions', () {
    test('parses session metadata including current marker', () async {
      final client = MockClient((req) async {
        expect(req.headers['authorization'], 'Bearer my-token');
        return http.Response(
          jsonEncode({
            'sessions': [
              {
                'id': 'sess-1',
                'deviceId': 'dev-a',
                'deviceName': 'Laptop',
                'createdAt': 1000,
                'expiresAt': 2000,
                'lastUsedAt': 1500,
                'legacy': false,
                'current': true,
              },
              {
                'id': 'sess-2',
                'deviceName': 'Phone',
                'createdAt': 900,
                'expiresAt': 1900,
                'lastUsedAt': 1400,
                'legacy': true,
                'current': false,
              },
            ],
          }),
          200,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final sessions = await sync.listSessions();

      expect(sessions, hasLength(2));
      expect(sessions[0].id, 'sess-1');
      expect(sessions[0].deviceId, 'dev-a');
      expect(sessions[0].deviceName, 'Laptop');
      expect(sessions[0].createdAt, 1000);
      expect(sessions[0].expiresAt, 2000);
      expect(sessions[0].lastUsedAt, 1500);
      expect(sessions[0].legacy, isFalse);
      expect(sessions[0].current, isTrue);

      expect(sessions[1].id, 'sess-2');
      expect(sessions[1].deviceId, isNull);
      expect(sessions[1].deviceName, 'Phone');
      expect(sessions[1].legacy, isTrue);
      expect(sessions[1].current, isFalse);
    });

    test('returns empty list when no sessions', () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({'sessions': []}), 200);
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final sessions = await sync.listSessions();
      expect(sessions, isEmpty);
    });
  });

  group('HttpSyncClient revokeSessionById', () {
    test('returns true and retains bearer for another session', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/v1/sessions/other-id');
        return http.Response(
          jsonEncode({'revoked': true, 'current': false}),
          200,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final result = await sync.revokeSessionById('other-id');

      expect(result, isTrue);
      expect(sync.token, 'my-token');
    });

    test('clears bearer only when revoked:true and current:true', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'revoked': true, 'current': true}),
          200,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final result = await sync.revokeSessionById('my-session');

      expect(result, isTrue);
      expect(sync.token, isNull);
    });

    test('retains bearer when revoked:false', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'revoked': false, 'current': false}),
          200,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final result = await sync.revokeSessionById('some-id');

      expect(result, isFalse);
      expect(sync.token, 'my-token');
    });

    test('returns false for structured 404 not_found', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'error': 'not_found', 'message': 'Session not found'}),
          404,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      final result = await sync.revokeSessionById('missing-id');

      expect(result, isFalse);
      expect(sync.token, 'my-token');
    });

    test('throws on plain 404 without structured error', () async {
      final client = MockClient((req) async {
        return http.Response('Not Found', 404);
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      await expectLater(
        sync.revokeSessionById('missing-id'),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'http_404')),
      );
      expect(sync.token, 'my-token');
    });

    test('throws on 500 and does not clear bearer', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'error': 'internal', 'message': 'Server error'}),
          500,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      await expectLater(
        sync.revokeSessionById('some-id'),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'internal')),
      );
      expect(sync.token, 'my-token');
    });

    test('safely URI-encodes session ID', () async {
      String? capturedPath;
      final client = MockClient((req) async {
        capturedPath = req.url.path;
        return http.Response(
          jsonEncode({'revoked': true, 'current': false}),
          200,
        );
      });

      final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
        ..token = 'my-token';

      await sync.revokeSessionById('id/with special chars&query');

      expect(capturedPath, '/v1/sessions/id%2Fwith%20special%20chars%26query');
    });
  });
}

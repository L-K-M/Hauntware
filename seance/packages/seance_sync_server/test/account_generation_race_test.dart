import 'dart:async';
import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _GateStorage extends InMemoryStorage {
  Completer<void>? principalReached;
  Completer<void>? principalRelease;
  Completer<void>? loginReached;
  Completer<void>? loginRelease;

  @override
  Future<AuthPrincipal?> principalForToken(
    String token, {
    required int now,
  }) async {
    final principal = await super.principalForToken(token, now: now);
    final reached = principalReached;
    final release = principalRelease;
    if (reached != null && release != null) {
      principalReached = null;
      reached.complete();
      await release.future;
    }
    return principal;
  }

  @override
  Future<String?> createTokenFor(
    Account account, {
    required int issuedAt,
    required int expiresAt,
    required int maxSessions,
    SessionDevice? device,
  }) async {
    final reached = loginReached;
    final release = loginRelease;
    if (reached != null && release != null) {
      loginReached = null;
      reached.complete();
      await release.future;
    }
    return super.createTokenFor(
      account,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maxSessions: maxSessions,
      device: device,
    );
  }
}

Future<Response> _request(
  Handler handler,
  String method,
  String path, {
  String? token,
  Map<String, Object?>? body,
}) => Future.sync(
  () => handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        'content-type': 'application/json',
        'x-seance-protocol-version': '$kProtocolVersion',
        if (token != null) 'authorization': 'Bearer $token',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  ),
);

final _verifier = base64.encode(List<int>.filled(32, 7));

Future<String> _register(Handler handler) async {
  final response = await _request(
    handler,
    'POST',
    '/v1/register',
    body: RegisterRequest(
      username: 'reused',
      authVerifier: _verifier,
      argonSalt: base64.encode(List<int>.filled(16, 4)),
      argonParams: const Argon2Params(),
      vaultKeyCheck: base64.encode(List<int>.filled(64, 5)),
    ).toJson(),
  );
  expect(response.statusCode, 200);
  return LoginResponse.fromJson(
    (jsonDecode(await response.readAsString()) as Map).cast<String, dynamic>(),
  ).token;
}

void main() {
  for (final endpoint in [
    ('GET', '/v1/sync?since=0'),
    ('DELETE', '/v1/account'),
  ]) {
    test(
      '${endpoint.$1} ${endpoint.$2} revalidates after account replacement',
      () async {
        final storage = _GateStorage();
        final handler = SyncServer(
          storage: storage,
          settings: const ServerSettings(openRegistration: true),
        ).handler;
        final oldToken = await _register(handler);
        final reached = storage.principalReached = Completer<void>();
        final release = storage.principalRelease = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final pending = _request(
          handler,
          endpoint.$1,
          endpoint.$2,
          token: oldToken,
        );
        await reached.future;

        await storage.deleteAccount('reused');
        final newToken = await _register(handler);
        final generation = (await storage.getAccount('reused'))!.generation;
        release.complete();

        expect((await pending).statusCode, 401);
        expect((await storage.getAccount('reused'))!.generation, generation);
        expect(await storage.usernameForToken(newToken), 'reused');
      },
    );
  }

  test(
    'a verified old login cannot mint a session for a replacement account',
    () async {
      final storage = _GateStorage();
      final handler = SyncServer(
        storage: storage,
        settings: const ServerSettings(openRegistration: true),
      ).handler;
      await _register(handler);
      final reached = storage.loginReached = Completer<void>();
      final release = storage.loginRelease = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final pending = _request(
        handler,
        'POST',
        '/v1/login',
        body: {
          'username': 'reused',
          'authVerifier': _verifier,
          'protocolVersion': kProtocolVersion,
        },
      );
      await reached.future;

      await storage.deleteAccount('reused');
      final newToken = await _register(handler);
      release.complete();

      expect((await pending).statusCode, 401);
      expect(await storage.usernameForToken(newToken), 'reused');
      final principal = (await storage.principalForToken(
        newToken,
        now: DateTime.now().millisecondsSinceEpoch,
      ))!;
      expect(
        await storage.listSessionsFor(
          principal,
          now: DateTime.now().millisecondsSinceEpoch,
        ),
        hasLength(1),
      );
    },
  );
}

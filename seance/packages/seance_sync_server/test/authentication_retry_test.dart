import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test(
    'login refusal advertises the remaining window and permits a later retry',
    () async {
      var now = DateTime.utc(2026);
      final handler = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(
          loginMaxAttempts: 1,
          loginWindow: Duration(seconds: 10),
        ),
        now: () => now,
      ).handler;

      Future<Response> login() => Future.sync(
        () => handler(
          Request(
            'POST',
            Uri.parse('http://localhost/v1/login'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'username': 'unknown',
              'authVerifier': base64.encode(List<int>.filled(32, 7)),
              'protocolVersion': kProtocolVersion,
            }),
          ),
        ),
      );

      expect((await login()).statusCode, 401);
      now = now.add(const Duration(seconds: 2));
      final limited = await login();
      expect(limited.statusCode, 429);
      expect(limited.headers['retry-after'], '8');
      now = now.add(const Duration(seconds: 8));
      final retry = await login();
      expect(retry.statusCode, 401);
      expect(retry.headers, isNot(contains('retry-after')));
    },
  );
}

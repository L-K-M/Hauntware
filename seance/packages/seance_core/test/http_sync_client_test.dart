import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('HttpSyncClient URL handling', () {
    test('tolerates a trailing slash in the base URL', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode({'token': 't'}), 200);
      });
      final sync = HttpSyncClient(
          baseUrl: 'https://seance.example.ch/', client: client);
      await sync.login(
          const LoginRequest(username: 'u', authVerifier: 'v'));
      expect(seen, Uri.parse('https://seance.example.ch/v1/login'));
    });

    test('trims whitespace and repeated slashes', () {
      final sync = HttpSyncClient(baseUrl: ' https://host// ');
      expect(sync.baseUrl, 'https://host');
    });

    test('leaves a clean base URL untouched', () {
      final sync = HttpSyncClient(baseUrl: 'http://localhost:8080');
      expect(sync.baseUrl, 'http://localhost:8080');
    });
  });

  group('HttpSyncClient error surfaces', () {
    HttpSyncClient failingWith(String body, int status) => HttpSyncClient(
          baseUrl: 'https://host',
          client: MockClient((req) async => http.Response(body, status)),
        );

    test("the server's own JSON errors pass through untouched", () async {
      final sync = failingWith(
          jsonEncode({'error': 'registration_closed', 'message': 'Registration is disabled'}),
          403);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'registration_closed')
            .having((e) => e.message, 'message', 'Registration is disabled')),
      );
    });

    test('a 502 (proxy could not reach the server) is explained, not echoed',
        () async {
      // Cloudflare-style plain-text body for API clients.
      final sync = failingWith('error code: 502', 502);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_502')
            .having((e) => e.message, 'message',
                contains('could not reach the sync server'))),
      );
    });

    test('an HTML error page never reaches the UI as raw markup', () async {
      final sync = failingWith(
          '<html>\n<head><title>404 Not Found</title></head>\n'
          '<body><h1>Not Found</h1><hr><center>nginx</center></body>\n</html>',
          404);
      try {
        await sync.pull(since: 0);
        fail('expected an ApiError');
      } on ApiError catch (e) {
        expect(e.code, 'http_404');
        expect(e.message, isNot(contains('<')));
        expect(e.message, contains('404 Not Found'));
      }
    });

    test('a huge body is capped to a short snippet', () async {
      final sync = failingWith('x' * 5000, 500);
      try {
        await sync.pull(since: 0);
        fail('expected an ApiError');
      } on ApiError catch (e) {
        expect(e.code, 'http_500');
        expect(e.message.length, lessThan(220));
      }
    });

    test('a JSON body that is not an object still maps to http_<status>',
        () async {
      // jsonDecode succeeds here; the old cast-based path threw a TypeError.
      final sync = failingWith('"boom"', 500);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_500')
            .having((e) => e.message, 'message', contains('boom'))),
      );
    });

    test('a JSON object without an error code is not mistaken for the server',
        () async {
      final sync = failingWith(jsonEncode({'detail': 'gateway exploded'}), 500);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_500')
            .having((e) => e.message, 'message', contains('gateway exploded'))),
      );
    });
  });

  group('HttpSyncClient timeout', () {
    test('a hung request times out instead of hanging forever', () async {
      final client = MockClient((req) async {
        // Never responds within the client's timeout.
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('{}', 200);
      });
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  test('listItems skips a malformed item instead of failing the list', () async {
    final good = {
      'app': 'AAAAAAAAAAAAAAAAAAAAAA',
      'item': 'i1',
      'received': 1,
      'blob': base64.encode(List<int>.filled(48, 0)),
    };
    final sync = HttpSyncClient(
      baseUrl: 'https://host',
      client: MockClient((req) async => http.Response(
            jsonEncode({
              'items': [
                {'app': 'x'},
                'not an object',
                good,
              ],
            }),
            200,
          )),
    );
    final items = await sync.listItems(since: 0);
    expect(items.map((i) => i.itemId), ['i1']);
  });

  group('HttpSyncClient.listItems paging', () {
    Map<String, Object> page(List<int> received, {Object? nextSince}) => {
          'items': [
            for (final r in received)
              {
                'app': 'AAAAAAAAAAAAAAAAAAAAAA',
                'item': 'i$r',
                'received': r,
                'blob': base64.encode(List<int>.filled(48, 0)),
              },
          ],
          if (nextSince != null) 'nextSince': nextSince,
        };

    HttpSyncClient pagingClient(
      Object? Function(int since) respond, {
      List<String>? sinces,
    }) {
      int calls = 0;
      return HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient((req) async {
          final since = req.url.queryParameters['since'] ?? '';
          calls++;
          sinces?.add(since);
          if (calls > 4) fail('more requests than the paging bound');
          return http.Response(jsonEncode(respond(int.tryParse(since) ?? 0)),
              200);
        }),
      );
    }

    test('follows a strictly increasing nextSince across pages', () async {
      final sinces = <String>[];
      final sync = pagingClient(
        (since) => since == 0 ? page([1, 2], nextSince: 2) : page([3]),
        sinces: sinces,
      );
      final items = await sync.listItems(since: 0);
      expect(items.map((i) => i.received), [1, 2, 3]);
      expect(sinces, ['0', '2']);
    });

    test('one response from an old server with no nextSince', () async {
      final sinces = <String>[];
      final sync = pagingClient(
        (since) => page([1, 2]),
        sinces: sinces,
      );
      final items = await sync.listItems(since: 0);
      expect(items.map((i) => i.received), [1, 2]);
      expect(sinces, ['0']);
      final scan = sync as InboxPageScan;
      expect(scan.inboxScanHasMore, isFalse);
    });

    test('stops after four responses however long the queue is', () async {
      final sinces = <String>[];
      final sync = pagingClient(
        (since) => page([since + 1], nextSince: since + 1),
        sinces: sinces,
      );
      final items = await sync.listItems(since: 0);
      expect(items.map((i) => i.received), [1, 2, 3, 4]);
      expect(sinces, ['0', '1', '2', '3']);
      final scan = sync as InboxPageScan;
      expect(scan.inboxScanHasMore, isTrue);
      expect(scan.inboxScanCursor, 4);
    });

    test('bounds a legacy unpaged response and exposes its continuation',
        () async {
      final sinces = <String>[];
      final sync = pagingClient(
        (since) => page([for (var i = 1; i <= 129; i++) since + i]),
        sinces: sinces,
      );
      final items = await sync.listItems(since: 0);
      expect(items, hasLength(128));
      expect(items.first.received, 1);
      expect(items.last.received, 128);
      expect(sinces, ['0']);
      final scan = sync as InboxPageScan;
      expect(scan.inboxScanHasMore, isTrue);
      expect(scan.inboxScanCursor, 128);
    });

    test('a non-integer continuation is a FormatException', () async {
      final sync = pagingClient((since) => page([1], nextSince: 'two'));
      await expectLater(
        sync.listItems(since: 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-increasing continuation is a FormatException', () async {
      for (final bad in [0, -1]) {
        final sync = pagingClient((since) => page([1], nextSince: bad));
        await expectLater(
          sync.listItems(since: 0),
          throwsA(isA<FormatException>()),
          reason: 'nextSince $bad',
        );
      }
      final stuck = pagingClient((since) => page([1], nextSince: 2));
      await expectLater(
        stuck.listItems(since: 2),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

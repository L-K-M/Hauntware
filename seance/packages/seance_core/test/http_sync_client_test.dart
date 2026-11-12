import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

EncryptedRecord _record(String id, int seq) => EncryptedRecord(
  id: id,
  updatedAt: seq,
  deviceId: 'device',
  deleted: false,
  seq: seq,
  blob: Uint8List.fromList([seq]),
);

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

    test('cursor rejection becomes the durable resync signal', () async {
      final sync = failingWith(
        jsonEncode({
          'error': 'cursor_rejected',
          'message': 'Sync cursor is no longer valid',
        }),
        409,
      );

      await expectLater(
        sync.pull(since: 42),
        throwsA(
          isA<SyncCursorRejectedException>().having(
            (error) => error.message,
            'message',
            'Sync cursor is no longer valid',
          ),
        ),
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

    // A page of up to 8 MiB on a slow link takes longer than the per-request
    // timeout, but keeps moving. Only a stall, or the overall cap, may end it.
    // Trailing whitespace stands in for records: about 30 chunks.
    final page = utf8.encode(
      jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()) +
          ' ' * 2000,
    );

    test('a slow download that keeps moving completes', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: _SlowClient(page, gap: const Duration(milliseconds: 10)),
        timeout: const Duration(milliseconds: 60),
      );
      final response = await sync.pullPage(since: 0);
      expect(response.latestSeq, 0);
    });

    test('a download that stalls between chunks times out', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: _SlowClient(
          page,
          gap: const Duration(milliseconds: 5),
          stallAfter: 3,
        ),
        timeout: const Duration(milliseconds: 60),
      );
      await expectLater(
        sync.pullPage(since: 0),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a transfer that never ends hits the overall cap', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: _SlowClient(
          List.filled(1 << 20, 0x20),
          gap: const Duration(milliseconds: 5),
        ),
        timeout: const Duration(milliseconds: 60),
        maxTransferDuration: const Duration(milliseconds: 150),
      );
      await expectLater(
        sync.pullPage(since: 0),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a slow upload that keeps moving completes', () async {
      final response = utf8.encode(
        jsonEncode(const PushResponse(results: [], latestSeq: 0).toJson()),
      );
      final client = _SlowClient(
        response,
        gap: const Duration(milliseconds: 1),
        uploadGap: const Duration(milliseconds: 10),
      );
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        timeout: const Duration(milliseconds: 60),
      );
      await sync.push([
        EncryptedRecord(
          id: 'big',
          updatedAt: 1,
          deviceId: 'device',
          deleted: false,
          seq: null,
          blob: Uint8List(256 * 1024),
        ),
      ]);
      expect(client.uploaded, greaterThan(256 * 1024));
    });
  });

  group('HttpSyncClient record pagination', () {
    test('aggregates a stable snapshot and carries the continuation', () async {
      final queries = <Map<String, String>>[];
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient((request) async {
          queries.add(request.url.queryParameters);
          final since = int.parse(request.url.queryParameters['since']!);
          expect(request.url.queryParameters['page'], '1');
          expect(
            request.url.queryParameters['protocolVersion'],
            '$kProtocolVersion',
          );
          final response = since == 4
              ? PullResponse(
                  records: [_record('a', 5)],
                  latestSeq: 9,
                  throughSeq: 9,
                  hasMore: true,
                )
              : PullResponse(
                  records: [_record('b', 9)],
                  latestSeq: 9,
                  throughSeq: 9,
                );
          return http.Response(jsonEncode(response.toJson()), 200);
        }),
      );

      final response = await sync.pull(since: 4);

      expect(response.records.map((record) => record.id), ['a', 'b']);
      expect(response.throughSeq, 9);
      expect(queries, [
        {'since': '4', 'page': '1', 'protocolVersion': '$kProtocolVersion'},
        {
          'since': '5',
          'page': '1',
          'protocolVersion': '$kProtocolVersion',
          'through': '9',
        },
      ]);
    });

    test('accepts a legacy one-response server', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(
              PullResponse(records: [_record('a', 3)], latestSeq: 7).toJson(),
            ),
            200,
          ),
        ),
      );

      final response = await sync.pull(since: 0);
      expect(response.records.single.id, 'a');
      expect(response.latestSeq, 7);
      expect(response.throughSeq, isNull);
    });

    test('rejects a page that changes the snapshot watermark', () async {
      var request = 0;
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient((_) async {
          request++;
          final response = PullResponse(
            records: [_record('r$request', request)],
            latestSeq: request == 1 ? 3 : 4,
            throughSeq: request == 1 ? 3 : 4,
            hasMore: request == 1,
          );
          return http.Response(jsonEncode(response.toJson()), 200);
        }),
      );

      await expectLater(sync.pull(since: 0), throwsFormatException);
    });

    test('rejects hasMore without an observed sequence', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(
              const PullResponse(
                records: [],
                latestSeq: 3,
                throughSeq: 3,
                hasMore: true,
              ).toJson(),
            ),
            200,
          ),
        ),
      );

      await expectLater(sync.pull(since: 0), throwsFormatException);
    });
  });

  test('session revocation uses the scoped routes and clears the token',
      () async {
    final paths = <String>[];
    final client = MockClient((req) async {
      paths.add(req.url.path);
      expect(req.method, 'DELETE');
      expect(req.headers['authorization'], 'Bearer secret');
      return http.Response('', 204);
    });
    final sync = HttpSyncClient(baseUrl: 'https://host', client: client);

    sync.token = 'secret';
    await sync.revokeSession();
    expect(sync.token, isNull);
    sync.token = 'secret';
    await sync.revokeAllSessions();
    expect(sync.token, isNull);
    expect(paths, ['/v1/session', '/v1/sessions']);
  });

  test('legacy key-check initialization authenticates and returns the winner',
      () async {
    final client = MockClient((req) async {
      expect(req.method, 'PUT');
      expect(req.url.path, '/v1/account/vault-key-check');
      expect(req.headers['authorization'], 'Bearer secret');
      expect(jsonDecode(req.body)['vaultKeyCheck'], 'proposed');
      return http.Response(jsonEncode({'vaultKeyCheck': 'winner'}), 200);
    });
    final sync = HttpSyncClient(baseUrl: 'https://host', client: client)
      ..token = 'secret';
    expect(await sync.initializeVaultKeyCheck('proposed'), 'winner');
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

  test('listItems aggregates bounded inbox pages', () async {
    final queries = <Map<String, String>>[];
    Map<String, dynamic> item(String id, int received) => {
      'app': 'AAAAAAAAAAAAAAAAAAAAAA',
      'item': id,
      'received': received,
      'blob': base64.encode(List<int>.filled(48, received)),
    };
    final sync = HttpSyncClient(
      baseUrl: 'https://host',
      client: MockClient((request) async {
        queries.add(request.url.queryParameters);
        final since = int.parse(request.url.queryParameters['since']!);
        return http.Response(
          jsonEncode(
            since == 0
                ? {
                    'items': [item('a', 1)],
                    'throughReceived': 3,
                    'nextReceived': 1,
                    'hasMore': true,
                  }
                : {
                    'items': [item('b', 3)],
                    'throughReceived': 3,
                    'nextReceived': 3,
                    'hasMore': false,
                  },
          ),
          200,
        );
      }),
    );

    expect((await sync.listItems(since: 0)).map((item) => item.itemId), [
      'a',
      'b',
    ]);
    expect(queries.first['since'], '0');
    expect(queries.first.containsKey('through'), isFalse);
    expect(queries.last['through'], '3');
    expect(queries.last['since'], '1');
  });

  test('listItems never continues past an item it did not observe', () async {
    final sync = HttpSyncClient(
      baseUrl: 'https://host',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {
                'app': 'AAAAAAAAAAAAAAAAAAAAAA',
                'item': 'a',
                'received': 1,
                'blob': base64.encode(List<int>.filled(48, 1)),
              },
            ],
            'throughReceived': 3,
            'nextReceived': 2,
            'hasMore': true,
          }),
          200,
        ),
      ),
    );

    await expectLater(sync.listItems(since: 0), throwsFormatException);
  });

  for (final metadata in [
    {'hasMore': true},
    {'throughReceived': 1, 'nextReceived': 0},
  ]) {
    test('listItems rejects incomplete page metadata $metadata', () async {
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: MockClient((_) async => http.Response(
          jsonEncode({'items': [], ...metadata}), 200,
        )),
      );
      await expectLater(sync.listItems(since: 0), throwsFormatException);
    });
  }
}

/// A transport that trickles bodies in small chunks, like a slow link.
///
/// The request body is read at [uploadGap] per started 16 KiB, however it is
/// chunked, and the response is sent at [gap] per 64-byte chunk. With
/// [stallAfter] the response stops after that many chunks and never finishes.
class _SlowClient extends http.BaseClient {
  _SlowClient(
    this._body, {
    required this.gap,
    this.uploadGap = Duration.zero,
    this.stallAfter,
  });

  static const _chunk = 64;
  static const _uploadBlock = 16 * 1024;

  final List<int> _body;
  final Duration gap;
  final Duration uploadGap;
  final int? stallAfter;
  int uploaded = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await for (final chunk in request.finalize()) {
      uploaded += chunk.length;
      final blocks = (chunk.length + _uploadBlock - 1) ~/ _uploadBlock;
      for (var block = 0; block < blocks; block++) {
        await Future<void>.delayed(uploadGap);
      }
    }
    return http.StreamedResponse(
      _trickle(),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }

  Stream<List<int>> _trickle() async* {
    var sent = 0;
    for (var offset = 0; offset < _body.length; offset += _chunk) {
      if (stallAfter != null && sent == stallAfter) {
        await Completer<void>().future;
      }
      await Future<void>.delayed(gap);
      yield _body.sublist(offset, min(offset + _chunk, _body.length));
      sent++;
    }
  }
}

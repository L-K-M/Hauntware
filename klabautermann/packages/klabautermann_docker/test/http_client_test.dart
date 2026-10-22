import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('request writer', () {
    late FakeDaemon daemon;
    late DockerHttpClient client;

    setUp(() {
      daemon = FakeDaemon();
      client = DockerHttpClient(() async => daemon.pair.client);
    });

    Future<void> answerOk() async {
      await daemon.gotBytes(1);
      daemon.feed(wireResponse('204 No Content'));
    }

    test('writes method, versioned path, Host and query', () async {
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'GET',
          path: '/v1.44/containers/json',
          query: {'all': '1', 'filters': '{"status":["running"]}'},
        ),
      );
      await answerOk();
      await sent;
      expect(
        daemon.text,
        'GET /v1.44/containers/json?all=1&'
        'filters=${Uri.encodeQueryComponent('{"status":["running"]}')}'
        ' HTTP/1.1\r\nHost: docker\r\n\r\n',
      );
    });

    test('writes JSON body with Content-Type and Content-Length', () async {
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'POST',
          path: '/v1.44/containers/create',
          json: {'Image': 'alpine', 'Tty': true},
        ),
      );
      await answerOk();
      await sent;
      const body = '{"Image":"alpine","Tty":true}';
      expect(
        daemon.text,
        'POST /v1.44/containers/create HTTP/1.1\r\n'
        'Host: docker\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${utf8Of(body).length}\r\n\r\n'
        '$body',
      );
    });

    test('writes Content-Length 0 on a bodiless POST', () async {
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'POST',
          path: '/v1.44/containers/x/start',
        ),
      );
      await answerOk();
      await sent;
      expect(daemon.text, endsWith('Content-Length: 0\r\n\r\n'));
    });

    test('writes Upgrade headers when asked', () async {
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'POST',
          path: '/v1.44/exec/abc/start',
          upgrade: true,
          json: {'Detach': false},
        ),
      );
      await answerOk();
      await sent;
      expect(daemon.text, contains('Connection: Upgrade\r\nUpgrade: tcp\r\n'));
    });

    test('drops caller copies of managed headers', () async {
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'GET',
          path: '/x',
          headers: {
            'Host': 'evil',
            'Content-Length': '99',
            'Connection': 'close',
            'Upgrade': 'h2',
            'X-Answer': '42',
          },
        ),
      );
      await answerOk();
      await sent;
      expect(daemon.text, contains('Host: docker\r\n'));
      expect(daemon.text, isNot(contains('evil')));
      expect(daemon.text, isNot(contains('Content-Length')));
      expect(daemon.text, contains('X-Answer: 42\r\n'));
    });

    test('rejects a CR/LF in the path before touching a connection', () async {
      var opens = 0;
      final c = DockerHttpClient(() async {
        opens++;
        return daemon.pair.client;
      });
      await expectThrows<ArgumentError>(
        c.sendBuffered(
          const DockerHttpRequest(method: 'GET', path: '/ok\r\nInjected: x'),
        ),
      );
      expect(opens, 0);
    });
  });

  group('response head parsing', () {
    late FakeDaemon daemon;
    late DockerHttpClient client;

    setUp(() {
      daemon = FakeDaemon();
      client = DockerHttpClient(() async => daemon.pair.client);
    });

    Future<DockerResponse<Uint8List>> roundTrip(List<int> wire) {
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'GET', path: '/x'),
      );
      daemon.feed(wire);
      return sent;
    }

    test('parses status code and reason', () async {
      final res = await roundTrip(
        wireResponse(
          '200 OK',
          headers: {'Content-Length': '2'},
          body: utf8Of('hi'),
        ),
      );
      expect(res.statusCode, 200);
      expect(res.reasonPhrase, 'OK');
      expect(utf8.decode(res.body), 'hi');
    });

    test('repeated headers collect into one list', () async {
      final res = await roundTrip(
        latin1.encode(
          'HTTP/1.1 200 OK\r\n'
          'X-Multi: a\r\nX-Multi: b\r\nContent-Length: 0\r\n\r\n',
        ),
      );
      expect(res.headers['x-multi'], ['a', 'b']);
    });

    test('header lookup is case-insensitive', () async {
      final res = await roundTrip(
        latin1.encode('HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 0\r\n\r\n'),
      );
      expect(res.headers.value('content-length'), '0');
    });

    test('skips a 100 Continue interim response', () async {
      final res = await roundTrip(<int>[
        ...latin1.encode('HTTP/1.1 100 Continue\r\nX-I: 1\r\n\r\n'),
        ...wireResponse(
          '200 OK',
          headers: {'Content-Length': '1'},
          body: utf8Of('z'),
        ),
      ]);
      expect(res.statusCode, 200);
      expect(utf8.decode(res.body), 'z');
    });

    test('a folded header line joins the previous value', () async {
      final res = await roundTrip(
        latin1.encode(
          'HTTP/1.1 200 OK\r\nX-Fold: one\r\n two\r\nContent-Length: 0\r\n\r\n',
        ),
      );
      expect(res.headers.value('x-fold'), 'one two');
    });

    test('malformed status line is a protocol error', () async {
      await expectThrows<DockerProtocolException>(
        roundTrip(latin1.encode('HELLO WORLD\r\n\r\n')),
      );
    });

    test('malformed header line is a protocol error', () async {
      await expectThrows<DockerProtocolException>(
        roundTrip(latin1.encode('HTTP/1.1 200 OK\r\nno colon here\r\n\r\n')),
      );
    });
  });

  group('head size caps', () {
    late FakeDaemon daemon;
    late DockerHttpClient client;

    setUp(() {
      daemon = FakeDaemon();
      client = DockerHttpClient(() async => daemon.pair.client);
    });

    Future<void> expectProtocolError(List<int> wire) {
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'GET', path: '/x'),
      );
      daemon.feed(wire);
      unawaited(daemon.eof());
      return expectThrows<DockerProtocolException>(sent);
    }

    test('status line over the 8 KiB cap', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 ${'r' * 9000}\r\n\r\n'),
      );
    });

    test('header line over the 16 KiB cap', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 OK\r\nX-Big: ${'v' * 20000}\r\n\r\n'),
      );
    });

    test('header block over the 64 KiB cap', () async {
      final wire = StringBuffer('HTTP/1.1 200 OK\r\n');
      // 70 lines of just over 1 KB each exceed the 64 KiB header block
      // cap while staying under the 16 KiB single-line and 128-count caps.
      for (var i = 0; i < 70; i++) {
        wire.write('X-H$i: ${'v' * 1000}\r\n');
      }
      wire.write('\r\n');
      await expectProtocolError(latin1.encode(wire.toString()));
    });

    test('more than 128 headers', () async {
      final wire = StringBuffer('HTTP/1.1 200 OK\r\n');
      for (var i = 0; i < 130; i++) {
        wire.write('X-H$i: v\r\n');
      }
      wire.write('\r\n');
      await expectProtocolError(latin1.encode(wire.toString()));
    });
  });

  group('body framing', () {
    final jsonBody = utf8Of('{"ok":true,"n":"${'7' * 500}"}');

    test('Content-Length body survives every split', () async {
      final wire = wireResponse(
        '200 OK',
        headers: {'Content-Length': '${jsonBody.length}'},
        body: jsonBody,
      );
      await forEverySplit<DockerResponse<Uint8List>>(
        wire,
        (c) =>
            c.sendBuffered(const DockerHttpRequest(method: 'GET', path: '/x')),
        (res) {
          expect(res.statusCode, 200);
          expect(res.body, jsonBody);
        },
      );
    });

    test(
      'chunked body with extensions and trailers survives every split',
      () async {
        final payload = 'the quick brown fox jumps over the lazy dog' * 4;
        String chunk(int size, String data, [String ext = '']) =>
            '${size.toRadixString(16)}$ext\r\n$data\r\n';
        final wire = latin1.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Transfer-Encoding: chunked\r\n\r\n'
          '${chunk(9, payload.substring(0, 9), ';ext=one;another')}'
          '${chunk(11, payload.substring(9, 20))}'
          '${chunk(payload.length - 20, payload.substring(20))}'
          '0\r\n'
          'X-Trailer: done\r\n'
          'Digest: abc\r\n\r\n',
        );
        await forEverySplit<DockerResponse<Uint8List>>(
          wire,
          (c) => c.sendBuffered(
            const DockerHttpRequest(method: 'GET', path: '/x'),
          ),
          (res) => expect(utf8.decode(res.body), payload),
        );
      },
    );

    test('close-delimited body survives every split', () async {
      final body = utf8Of('{"data":[1,2,3],"end":true}');
      final wire = wireResponse('200 OK', body: body);
      await forEverySplit<DockerResponse<Uint8List>>(
        wire,
        (c) =>
            c.sendBuffered(const DockerHttpRequest(method: 'GET', path: '/x')),
        (res) => expect(res.body, body),
        eof: true,
      );
    });

    test('a 204 response carries no body', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'DELETE', path: '/x'),
      );
      daemon.feed(wireResponse('204 No Content'));
      final res = await sent;
      expect(res.body, isEmpty);
    });

    test('a HEAD response carries no body even with Content-Length', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'HEAD', path: '/_ping'),
      );
      daemon.feed(wireResponse('200 OK', headers: {'Content-Length': '4'}));
      final res = await sent;
      expect(res.body, isEmpty);
    });
  });

  group('malformed bodies', () {
    late FakeDaemon daemon;
    late DockerHttpClient client;

    setUp(() {
      daemon = FakeDaemon();
      client = DockerHttpClient(() async => daemon.pair.client);
    });

    Future<void> expectProtocolError(List<int> wire, {bool eof = true}) {
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'GET', path: '/x'),
      );
      daemon.feed(wire);
      if (eof) unawaited(daemon.eof());
      return expectThrows<DockerProtocolException>(sent);
    }

    test('non-hex chunk size', () async {
      await expectProtocolError(
        latin1.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n',
        ),
      );
    });

    test('missing CRLF after chunk data', () async {
      await expectProtocolError(
        latin1.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX',
        ),
      );
    });

    test('chunk data truncated then EOF', () async {
      // The declared 9 bytes never arrive; a lone CR is the whole tail.
      await expectProtocolError(
        latin1.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nabc\r',
        ),
      );
    });

    test('conflicting Content-Length headers', () async {
      await expectProtocolError(
        latin1.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 3\r\nContent-Length: 4\r\n\r\nabcd',
        ),
      );
    });

    test('non-numeric Content-Length', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n'),
      );
    });

    test('Content-Length body truncated by EOF', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab'),
      );
    });

    test('EOF before any response bytes', () async {
      await expectProtocolError(utf8Of(''));
    });

    test('EOF mid status line is a protocol error, not a hang', () async {
      await expectProtocolError(latin1.encode('HTTP/1.1 200 O'));
    });

    test('EOF mid header line is a protocol error, not a hang', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 OK\r\nContent-Leng'),
      );
    });

    test('EOF mid chunk-size line is a protocol error, not a hang', () async {
      await expectProtocolError(
        latin1.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3'),
      );
    });
  });

  group('buffered cap', () {
    test('body over maxBytes fails with DockerBodyTooLargeException', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBuffered(
        const DockerHttpRequest(method: 'GET', path: '/x'),
        maxBytes: 4,
      );
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {'Content-Length': '10'},
          body: utf8Of('0123456789'),
        ),
      );
      final e = await expectThrows<DockerBodyTooLargeException>(sent);
      expect(e.maxBytes, 4);
    });
  });

  group('a line split across socket reads', () {
    // A real socket delivers its next read as an event, not a microtask,
    // so a partial line must wait for the event loop instead of spinning.
    // A spinning read also starves timers, so each request runs in an
    // isolate of its own and this one keeps the time.
    test('a status line whose LF comes in a later read', () async {
      final status = await _splitRequestStatus([
        latin1.encode('HTTP/1.1 204 No Content\r'),
        latin1.encode('\n\r\n'),
      ]);
      expect(status, 204);
    });

    test('a chunk whose closing CRLF comes in a later read', () async {
      final status = await _splitRequestStatus([
        latin1.encode(
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
          '3\r\nabc\r',
        ),
        latin1.encode('\n0\r\n\r\n'),
      ]);
      expect(status, 200);
    });
  });
}

/// The status of a GET answered with [reads], each fed after the event
/// loop has turned, or null when no answer came within five seconds.
Future<int?> _splitRequestStatus(List<List<int>> reads) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(_splitRequest, (port.sendPort, reads));
  try {
    return await port.first.timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        )
        as int?;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    port.close();
  }
}

Future<void> _splitRequest((SendPort, List<List<int>>) args) async {
  final (reply, reads) = args;
  final daemon = FakeDaemon();
  final client = DockerHttpClient(() async => daemon.pair.client);
  final response = client.sendBuffered(
    const DockerHttpRequest(method: 'GET', path: '/x'),
  );
  await daemon.gotBytes(1);
  for (final read in reads) {
    daemon.feed(read);
    await Future<void>.delayed(Duration.zero);
  }
  reply.send((await response).statusCode);
}

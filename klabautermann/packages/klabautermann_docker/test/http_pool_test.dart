import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// Vends a fresh [FakeDaemon] per opened duplex; records each one.
final class DaemonFarm {
  final daemons = <FakeDaemon>[];
  var opens = 0;

  DuplexOpener get opener => () async {
    opens++;
    final d = FakeDaemon();
    daemons.add(d);
    return d.pair.client;
  };

  DockerHttpClient client({int? maxConnections}) => DockerHttpClient(
    opener,
    maxConnections: maxConnections ?? defaultMaxConnections,
  );
}

DockerHttpRequest getX([String path = '/x']) =>
    DockerHttpRequest(method: 'GET', path: path);

void main() {
  group('connection reuse', () {
    test('a keep-alive connection serves the next request', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final ok = wireResponse(
        '200 OK',
        headers: {'Content-Length': '2'},
        body: utf8Of('hi'),
      );

      final first = client.sendBuffered(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(ok);
      await first;

      final sent = farm.daemons[0].received.length;
      final second = client.sendBuffered(getX('/y'));
      await farm.daemons[0].gotBytes(sent + 1);
      farm.daemons[0].feed(ok);
      await second;

      expect(farm.opens, 1);
      expect(farm.daemons[0].text, contains('GET /y HTTP/1.1'));
    });

    test('Connection: close retires the connection', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final first = client.sendBuffered(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(
        wireResponse(
          '200 OK',
          headers: {'Content-Length': '0', 'Connection': 'close'},
        ),
      );
      await first;
      await farm.daemons[0].pair.server.done;

      final second = client.sendBuffered(getX());
      await pumpEventQueue();
      expect(farm.opens, 2);
      await farm.daemons[1].gotBytes(1);
      farm.daemons[1].feed(
        wireResponse('200 OK', headers: {'Content-Length': '0'}),
      );
      await second;
    });

    test('a close-delimited response retires the connection', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final first = client.sendBuffered(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(wireResponse('200 OK', body: utf8Of('bye')));
      unawaited(farm.daemons[0].eof());
      await first;

      final second = client.sendBuffered(getX());
      await pumpEventQueue();
      expect(farm.opens, 2);
      await farm.daemons[1].gotBytes(1);
      farm.daemons[1].feed(
        wireResponse('200 OK', headers: {'Content-Length': '0'}),
      );
      await second;
    });

    test('a cancelled body stream retires the connection', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final res = await () async {
        final r = client.sendBytes(getX());
        await farm.daemons[0].gotBytes(1);
        farm.daemons[0].feed(
          wireResponse(
            '200 OK',
            headers: {'Content-Length': '4'},
            body: utf8Of('hi'),
          ),
        );
        return r;
      }();
      final sub = res.body.listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      expect(client.connectionCount, 0);
    });
  });

  group('serialization and pool cap', () {
    test('requests on one connection are serialized', () async {
      final farm = DaemonFarm();
      final client = farm.client(maxConnections: 1);
      // One streaming request holds the only connection while a second
      // request is issued: it queues until the body finishes, then reuses
      // the same duplex (03 §5.5: no pipelining).
      final first = client.sendBytes(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(
        wireResponse('200 OK', headers: {'Content-Length': '3'}),
      );
      final firstRes = await first;
      final second = client.sendBuffered(getX('/y'));
      await pumpEventQueue();
      final sent = farm.daemons[0].received.length;
      farm.daemons[0].feed(utf8Of('abc'));
      await firstRes.body.drain<void>();
      await farm.daemons[0].gotBytes(sent + 1);
      farm.daemons[0].feed(
        wireResponse('200 OK', headers: {'Content-Length': '0'}),
      );
      await second;
      expect(farm.opens, 1);
    });

    test('a busy connection makes the pool open another duplex', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final first = client.sendBytes(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(
        wireResponse('200 OK', headers: {'Content-Length': '999'}),
      );
      await first;

      final second = client.sendBuffered(getX('/y'));
      await farm.daemons[1].gotBytes(1);
      expect(farm.opens, 2);
      farm.daemons[1].feed(
        wireResponse('200 OK', headers: {'Content-Length': '0'}),
      );
      await second;
    });

    test('the cap queues requests until a connection frees', () async {
      final farm = DaemonFarm();
      final client = farm.client(maxConnections: 2);
      final ok = wireResponse('200 OK', headers: {'Content-Length': '0'});

      final r1 = client.sendBuffered(getX('/a'));
      await farm.daemons[0].gotBytes(1);
      final r2 = client.sendBuffered(getX('/b'));
      await farm.daemons[1].gotBytes(1);
      expect(farm.opens, 2);

      // Third request is queued: no opener call while both are busy.
      var r3Done = false;
      final r3 = client.sendBuffered(getX('/c')).then((r) {
        r3Done = true;
        return r;
      });
      await pumpEventQueue();
      expect(farm.opens, 2);
      expect(r3Done, isFalse);

      farm.daemons[0].feed(ok);
      await r1;
      // The freed connection is handed to r3 on the same daemon. The
      // handoff may happen before this frame resumes, so wait for the
      // request text rather than a byte count.
      await farm.daemons[0].gotText('GET /c HTTP/1.1');
      farm.daemons[0].feed(ok);
      farm.daemons[1].feed(ok);
      await r3;
      expect(r3Done, isTrue);
      expect(farm.opens, 2);
      await r2;
    });
  });

  group('typed status failures', () {
    late FakeDaemon daemon;
    late DockerHttpClient client;

    setUp(() {
      daemon = FakeDaemon();
      client = DockerHttpClient(() async => daemon.pair.client);
    });

    Future<void> respond(List<int> wire) async {
      await daemon.gotBytes(1);
      daemon.feed(wire);
    }

    Future<T> failsWith<T extends Object>(List<int> wire) async {
      final sent = client.sendBuffered(getX());
      unawaited(respond(wire));
      return expectThrows<T>(sent);
    }

    test(
      '404 maps to DockerNotFoundException with the daemon message',
      () async {
        final body = utf8Of('{"message":"No such container: abc"}');
        final e = await failsWith<DockerNotFoundException>(
          wireResponse(
            '404 Not Found',
            headers: {'Content-Length': '${body.length}'},
            body: body,
          ),
        );
        expect(e.statusCode, 404);
        expect(e.daemonMessage, 'No such container: abc');
      },
    );

    test('409 keeps the daemon message for display', () async {
      final body = utf8Of('{"message":"container already exists: /web"}');
      final e = await failsWith<DockerConflictException>(
        wireResponse(
          '409 Conflict',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      expect(e.daemonMessage, 'container already exists: /web');
    });

    test('500 maps to DockerServerException', () async {
      final body = utf8Of('{"message":"driver failed"}');
      final e = await failsWith<DockerServerException>(
        wireResponse(
          '500 Internal Server Error',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      expect(e.statusCode, 500);
    });

    test('a version-shaped 400 parses the reported versions', () async {
      final body = utf8Of(
        '{"message":"client version 1.55 is too new. Maximum supported API '
        'version is 1.44"}',
      );
      final e = await failsWith<DockerVersionException>(
        wireResponse(
          '400 Bad Request',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      expect(e.clientVersion, const ApiVersion(1, 55));
      expect(e.serverMaxVersion, const ApiVersion(1, 44));
    });

    test('a plain 400 maps to DockerBadRequestException', () async {
      final body = utf8Of('{"message":"bad parameter"}');
      final e = await failsWith<DockerBadRequestException>(
        wireResponse(
          '400 Bad Request',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      expect(e.daemonMessage, 'bad parameter');
    });

    test('another status maps to DockerUnexpectedStatusException', () async {
      final e = await failsWith<DockerUnexpectedStatusException>(
        wireResponse('418 I am a Teapot', headers: {'Content-Length': '0'}),
      );
      expect(e.statusCode, 418);
    });

    test('a non-JSON error body becomes the message', () async {
      final body = utf8Of('service unavailable\n');
      final e = await failsWith<DockerServerException>(
        wireResponse(
          '503 Service Unavailable',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      expect(e.daemonMessage, 'service unavailable');
    });

    test('the error body drains so the connection stays usable', () async {
      final farm = DaemonFarm();
      final c = farm.client();
      final body = utf8Of('{"message":"nope"}');
      final sent = c.sendBuffered(getX());
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(
        wireResponse(
          '404 Not Found',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      await expectThrows<DockerNotFoundException>(sent);

      final ok = c.sendBuffered(getX('/next'));
      await farm.daemons[0].gotBytes(farm.daemons[0].received.length + 1);
      farm.daemons[0].feed(
        wireResponse('200 OK', headers: {'Content-Length': '0'}),
      );
      await ok;
      expect(farm.opens, 1);
    });
  });

  group('transport failures, timeout, cancel', () {
    test('an opener failure is a DockerTransportException', () async {
      final client = DockerHttpClient(
        () async => throw StateError('socket gone'),
      );
      await expectThrows<DockerTransportException>(client.sendBuffered(getX()));
    });

    test('a per-request timeout fails and closes the duplex', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBuffered(
        const DockerHttpRequest(
          method: 'GET',
          path: '/x',
          timeout: Duration(milliseconds: 60),
        ),
      );
      await daemon.gotBytes(1);
      final e = await expectThrows<DockerTimeoutException>(sent);
      expect(e.timeout, const Duration(milliseconds: 60));
      await daemon.closed.future;
    });

    test('cancellation closes the duplex and reports cancelled', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final token = DockerCancelToken();
      final sent = client.sendBuffered(
        DockerHttpRequest(method: 'GET', path: '/x', cancelToken: token),
      );
      await daemon.gotBytes(1);
      token.cancel();
      await expectThrows<DockerCancelledException>(sent);
      await daemon.closed.future;
    });

    test('a remote hangup mid-headers is a protocol error', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBuffered(getX());
      await daemon.gotBytes(1);
      daemon.feed(latin1.encode('HTTP/1.1 200 OK\r\nContent-'));
      await daemon.hangup();
      await expectThrows<DockerProtocolException>(sent);
    });
  });

  group('hijack', () {
    test('101 hands over the duplex with buffered bytes first', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendHijack(
        const DockerHttpRequest(
          method: 'POST',
          path: '/v1.44/exec/abc/start',
          upgrade: true,
        ),
      );
      await daemon.gotBytes(1);
      daemon.feed(
        latin1.encode(
          'HTTP/1.1 101 UPGRADED\r\n'
          'Connection: Upgrade\r\nUpgrade: tcp\r\n\r\nPREBUFFERED',
        ),
      );
      final res = await sent;
      expect(res.statusCode, 101);

      final received = StringBuffer();
      final sub = res.body.stream
          .map((c) => latin1.decode(c))
          .listen(received.write);
      await pumpEventQueue();
      expect(received.toString(), 'PREBUFFERED');

      // Live bytes keep flowing on the same duplex.
      daemon.feed(utf8Of('LIVE'));
      await pumpEventQueue();
      expect(received.toString(), 'PREBUFFEREDLIVE');

      // Writes go back over the hijacked sink.
      res.body.sink.add(utf8Of('STDIN'));
      await pumpEventQueue();
      expect(daemon.text, endsWith('STDIN'));

      // Half-close signals stdin EOF without killing the read side.
      await res.body.closeWrite();
      await pumpEventQueue();
      daemon.feed(utf8Of('MORE'));
      await pumpEventQueue();
      expect(received.toString(), 'PREBUFFEREDLIVEMORE');
      await res.body.close();
      await sub.cancel();
    });

    test('200 on attach also hijacks', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendHijack(
        const DockerHttpRequest(
          method: 'GET',
          path: '/v1.44/containers/x/attach',
        ),
      );
      await daemon.gotBytes(1);
      daemon.feed(
        latin1.encode(
          'HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n',
        ),
      );
      final res = await sent;
      expect(res.statusCode, 200);
      expect(res.body, isA<HijackedDuplex>());
      await res.body.close();
    });

    test('a non-upgrade status is a typed failure, not a hijack', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendHijack(
        const DockerHttpRequest(
          method: 'POST',
          path: '/v1.44/exec/missing/start',
        ),
      );
      await daemon.gotBytes(1);
      final body = utf8Of('{"message":"No such exec instance"}');
      daemon.feed(
        wireResponse(
          '404 Not Found',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      await expectThrows<DockerNotFoundException>(sent);
    });

    test('the hijacked connection leaves the pool', () async {
      final farm = DaemonFarm();
      final client = farm.client();
      final sent = client.sendHijack(
        const DockerHttpRequest(method: 'POST', path: '/x'),
      );
      await farm.daemons[0].gotBytes(1);
      farm.daemons[0].feed(latin1.encode('HTTP/1.1 101 UPGRADED\r\n\r\n'));
      final res = await sent;
      // It still counts as a live duplex until closed.
      expect(client.connectionCount, 1);
      await res.body.close();
      await pumpEventQueue();
      expect(client.connectionCount, 0);
    });
  });

  group('backpressure', () {
    test('a paused body stream pauses the duplex subscription', () async {
      final daemon = FakeDaemon();
      final client = DockerHttpClient(() async => daemon.pair.client);
      final sent = client.sendBytes(getX());
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse('200 OK', headers: {'Content-Length': '1000000'}),
      );
      final res = await sent;
      final sub = res.body.listen((_) {});
      sub.pause();
      await pumpEventQueue();
      expect(daemon.pair.clientReadPaused, isTrue);
      sub.resume();
      await pumpEventQueue();
      expect(daemon.pair.clientReadPaused, isFalse);
      await sub.cancel();
    });
  });

  group('client close', () {
    test('close fails in-flight and queued requests', () async {
      final farm = DaemonFarm();
      final client = farm.client(maxConnections: 1);
      final r1 = client.sendBuffered(getX('/a'));
      await farm.daemons[0].gotBytes(1);
      final r2 = client.sendBuffered(getX('/b'));
      await pumpEventQueue();
      unawaited(client.close());
      await expectThrows<DockerTransportException>(r1);
      await expectThrows<DockerTransportException>(r2);
    });
  });
}

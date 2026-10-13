import 'dart:async';

import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('FakeDuplexPair', () {
    test('bytes written on one end arrive on the other', () async {
      final pair = FakeDuplexPair();
      pair.client.sink.add(utf8Of('ping'));
      pair.server.sink.add(utf8Of('pong'));
      expect(await pair.client.stream.first, utf8Of('pong'));
      expect(await pair.server.stream.first, utf8Of('ping'));
    });

    test('closeWrite half-closes only the writer direction', () async {
      final pair = FakeDuplexPair();
      final serverInboundDone = pair.server.stream.drain<void>();
      await pair.client.closeWrite();
      await serverInboundDone;
      // The server can still write back to the client.
      pair.server.sink.add(utf8Of('tail'));
      expect(await pair.client.stream.first, utf8Of('tail'));
    });

    test('close on one end closes both directions', () async {
      final pair = FakeDuplexPair();
      unawaited(pair.client.close());
      await pair.server.done;
      await pair.client.done;
    });
  });
}

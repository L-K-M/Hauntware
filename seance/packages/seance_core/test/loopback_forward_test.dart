import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A stream to the target that answers each write in upper case.
final class _ShoutingDuplex implements ByteDuplex {
  _ShoutingDuplex() {
    _outbound.stream.listen(
      (bytes) => _inbound.add(utf8.encode(utf8.decode(bytes).toUpperCase())),
      onDone: _inbound.close,
    );
  }

  final _inbound = StreamController<List<int>>();
  final _outbound = StreamController<List<int>>();
  bool closed = false;

  @override
  Stream<List<int>> get stream => _inbound.stream;

  @override
  StreamSink<List<int>> get sink => _outbound.sink;

  @override
  Future<void> get done => _inbound.done;

  @override
  Future<void> close() async {
    closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }
}

Future<String> _ask(int port, String text) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.add(utf8.encode(text));
  await socket.close();
  return utf8.decode(await socket.expand((bytes) => bytes).toList());
}

void main() {
  test('relays each connection to the target', () async {
    final streams = <_ShoutingDuplex>[];
    final forward = await LoopbackForward.bind(() async {
      final stream = _ShoutingDuplex();
      streams.add(stream);
      return stream;
    });
    addTearDown(forward.close);

    expect(await _ask(forward.port, 'hello'), 'HELLO');
    expect(await _ask(forward.port, 'again'), 'AGAIN');
    expect(streams, hasLength(2));
  });

  test('takes the server\'s own port when it is free', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = probe.port;
    await probe.close();

    final forward = await LoopbackForward.bind(
      () async => _ShoutingDuplex(),
      preferredPort: free,
    );
    addTearDown(forward.close);
    expect(forward.port, free);
  });

  test('takes another port when the server\'s is in use here', () async {
    final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(busy.close);

    final forward = await LoopbackForward.bind(
      () async => _ShoutingDuplex(),
      preferredPort: busy.port,
    );
    addTearDown(forward.close);
    expect(forward.port, isNot(busy.port));
    expect(await _ask(forward.port, 'ok'), 'OK');
  });

  test('a stream that cannot open ends only that connection', () async {
    var calls = 0;
    final forward = await LoopbackForward.bind(() async {
      calls++;
      if (calls == 1) throw StateError('refused');
      return _ShoutingDuplex();
    });
    addTearDown(forward.close);

    expect(await _ask(forward.port, 'lost'), isEmpty);
    expect(await _ask(forward.port, 'kept'), 'KEPT');
  });

  test('close ends open connections and stops listening', () async {
    final stream = _ShoutingDuplex();
    final forward = await LoopbackForward.bind(() async => stream);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      forward.port,
    );
    final ended = socket.drain<void>();
    // Let the relay take the connection before closing.
    socket.add(utf8.encode('x'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await forward.close();
    await ended.timeout(const Duration(seconds: 5));
    expect(stream.closed, isTrue);
    expect(forward.isClosed, isTrue);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, forward.port),
      throwsA(isA<SocketException>()),
    );
  });
}

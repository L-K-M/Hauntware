import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_terminal/seance_terminal.dart';

/// A far end the test drives: what it printed, what was typed to it, its
/// sizes, and how often it was closed.
final class _Transport implements TerminalByteTransport {
  final far = StreamController<Uint8List>();
  final written = <List<int>>[];
  final sizes = <(int, int)>[];
  var closes = 0;

  @override
  Stream<Uint8List> get output => far.stream;

  @override
  void write(Uint8List bytes) => written.add(bytes);

  @override
  void resize({required int columns, required int rows}) =>
      sizes.add((columns, rows));

  @override
  Future<void> close() async => closes++;

  void print(String text) => far.add(Uint8List.fromList(utf8.encode(text)));
}

void main() {
  late XtermTerminalEngine engine;
  late _Transport transport;
  late TerminalByteSession session;

  setUp(() {
    engine = XtermTerminalEngine();
    transport = _Transport();
    session = TerminalByteSession(engine: engine, transport: transport);
  });

  tearDown(() => session.close());

  test('bytes from the far end reach the terminal buffer', () async {
    transport.print('hello from the container');
    await pumpEventQueue();

    expect(
      engine.terminal.buffer.lines[0].toString(),
      startsWith('hello from the container'),
    );
  });

  test('typed bytes reach the far end', () async {
    engine.terminal.textInput('ls');
    await pumpEventQueue();

    expect(utf8.decode(transport.written.expand((b) => b).toList()), 'ls');
  });

  test('a resize reaches the far end with columns and rows named', () async {
    engine.terminal.resize(132, 43);
    await pumpEventQueue();

    expect(transport.sizes.last, (132, 43));
    expect(engine.size.cols, 132);
    expect(engine.size.rows, 43);
  });

  test('the far end ending fires onClosed once and stops input', () async {
    var closed = 0;
    session.onClosed = () => closed++;

    await transport.far.close();
    await pumpEventQueue();
    engine.terminal.textInput('late');
    await pumpEventQueue();

    expect(closed, 1);
    expect(transport.written, isEmpty);
    // The engine stays, so the host can still show what was printed.
    expect(session.isClosed, isFalse);
  });

  test('onClosed assigned after the far end ended still fires', () async {
    await transport.far.close();
    await pumpEventQueue();

    var closed = 0;
    session.onClosed = () => closed++;
    await pumpEventQueue();

    expect(closed, 1);
  });

  test('a failing far end tears down and fires onClosed once', () async {
    var closed = 0;
    session.onClosed = () => closed++;

    transport.far.addError(StateError('the stream broke'));
    await pumpEventQueue();

    expect(closed, 1);
    expect(session.isClosed, isTrue);
    expect(transport.closes, 1);
  });

  test('close twice closes the far end and disposes the engine once', () async {
    await Future.wait([session.close(), session.close()]);
    await session.close();

    expect(transport.closes, 1);
    expect(session.isClosed, isTrue);
  });

  test('nothing is written after close, and late output is ignored', () async {
    await session.close();
    engine.terminal.textInput('after');
    await pumpEventQueue();

    expect(transport.written, isEmpty);
    expect(transport.far.hasListener, isFalse);
  });
}

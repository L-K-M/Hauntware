import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/engine_reads.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// An engine whose port refuses requests while [refusing], with its
/// events still open.
final class _Engine implements EngineClient {
  final _events = StreamController<EngineEvent>.broadcast();
  final sent = <EngineRequest>[];
  bool refusing = false;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  void send(EngineRequest request) {
    if (refusing) throw StateError('closed');
    sent.add(request);
  }

  void emit(EngineEvent event) => _events.add(event);

  @override
  Future<void> shutdown() => _events.close();
}

/// The one-shot read bookkeeping the engine read controllers share: an
/// answer finds its read by request id, a stopped engine answers every
/// read's no-link value, and a refused send costs that read or, where the
/// concern says a closed port is a stopped engine, every read.
void main() {
  late _Engine engine;
  setUp(() => engine = _Engine());

  EngineReads<String> reads([SendFailure failure = SendFailure.thisRead]) =>
      EngineReads<String>(
        engine,
        (event) => switch (event) {
          AccountsReport(:final requestId, :final serverId) => (
            requestId,
            serverId,
          ),
          _ => null,
        },
        sendFailure: failure,
      );

  ReadAccounts request(String id) => ReadAccounts('srv-1', requestId: id);

  test('each answer completes the read of its request id', () async {
    final subject = reads();
    final first = subject.read('a', request('a'), () => 'no link');
    final second = subject.read('b', request('b'), () => 'no link');
    engine.emit(const AccountsReport(serverId: 'second', requestId: 'b'));
    engine.emit(const AccountsReport(serverId: 'first', requestId: 'a'));

    expect(await first, 'first');
    expect(await second, 'second');
    expect(engine.sent, hasLength(2));
  });

  test(
    'a stopped engine answers waiting and later reads with no link',
    () async {
      final subject = reads();
      final waiting = subject.read('a', request('a'), () => 'no link a');
      await engine.shutdown();

      expect(await waiting, 'no link a');
      expect(
        await subject.read('b', request('b'), () => 'no link b'),
        'no link b',
      );
      expect(engine.sent, hasLength(1));
    },
  );

  test('a refused send costs only that read, or every read where a closed '
      'port means a stopped engine', () async {
    final one = reads();
    final waiting = one.read('a', request('a'), () => 'no link');
    engine.refusing = true;
    expect(await one.read('b', request('b'), () => 'refused'), 'refused');
    engine.refusing = false;
    engine.emit(const AccountsReport(serverId: 'answered', requestId: 'a'));
    expect(await waiting, 'answered');

    final every = reads(SendFailure.engineStopped);
    final earlier = every.read('c', request('c'), () => 'no link c');
    engine.refusing = true;
    expect(await every.read('d', request('d'), () => 'no link d'), 'no link d');
    expect(await earlier, 'no link c');
    engine.refusing = false;
    expect(await every.read('e', request('e'), () => 'no link e'), 'no link e');
  });
}

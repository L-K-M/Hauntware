// `InboundReplay` is the buffer between a dartssh2 channel stream and a
// consumer that may listen late; these cases pin its error delivery.
import 'dart:async';
import 'dart:typed_data';

import 'package:seance_core/src/ssh/byte_duplex.dart';
import 'package:test/test.dart';

void main() {
  test('reports each error with its own stack trace', () async {
    final source = StreamController<Uint8List>();
    addTearDown(source.close);
    final replay = InboundReplay(source.stream, maxBufferedBytes: 1024);
    final traces = <String>[];
    replay.stream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) =>
          traces.add('$error @ $stackTrace'),
    );

    source.addError(StateError('first'), StackTrace.fromString('trace-1'));
    await pumpEventQueue();
    source.addError(StateError('second'), StackTrace.fromString('trace-2'));
    await pumpEventQueue();

    expect(traces, [
      'Bad state: first @ trace-1',
      'Bad state: second @ trace-2',
    ]);
  });

  test('discard-oldest mode keeps the exact newest byte bound', () async {
    var sourcePauses = 0;
    final source = StreamController<List<int>>(onPause: () => sourcePauses++);
    final replay = InboundReplay(
      source.stream,
      maxBufferedBytes: 5,
      overflow: InboundReplayOverflow.discardOldest,
    );

    source
      ..add([1, 2, 3])
      ..add([4, 5, 6, 7]);
    await source.close();

    expect(await replay.stream.expand((chunk) => chunk).toList(), [
      3,
      4,
      5,
      6,
      7,
    ]);
    expect(sourcePauses, 0);
  });

  test(
    'discard-oldest mode keeps draining while its listener is paused',
    () async {
      var sourcePauses = 0;
      final source = StreamController<List<int>>(onPause: () => sourcePauses++);
      final replay = InboundReplay(
        source.stream,
        maxBufferedBytes: 4,
        overflow: InboundReplayOverflow.discardOldest,
      );
      final received = <int>[];
      final done = Completer<void>();
      final subscription = replay.stream.listen(
        received.addAll,
        onDone: done.complete,
      );
      subscription.pause();

      source
        ..add([1, 2, 3])
        ..add([4, 5, 6]);
      await pumpEventQueue();

      expect(sourcePauses, 0);
      subscription.resume();
      await source.close();
      await done.future;
      expect(received, [3, 4, 5, 6]);
    },
  );

  test(
    'discard-oldest mode keeps draining after listener cancellation',
    () async {
      var sourcePauses = 0;
      var chunksSeen = 0;
      final source = StreamController<List<int>>(onPause: () => sourcePauses++);
      final replay = InboundReplay(
        source.stream,
        maxBufferedBytes: 4,
        overflow: InboundReplayOverflow.discardOldest,
        onData: () => chunksSeen++,
      );
      final subscription = replay.stream.listen((_) {});
      await subscription.cancel();

      source
        ..add([1, 2, 3])
        ..add([4, 5, 6]);
      await source.close();

      expect(sourcePauses, 0);
      expect(chunksSeen, 2);
    },
  );
}

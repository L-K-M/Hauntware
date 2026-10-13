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
    final replay = InboundReplay(source.stream);
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
}

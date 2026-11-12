import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/serialized_operations.dart';

class _Queue with SerializedOperations {
  final List<int> events = [];
  int loads = 0;

  Future<void> run(int id, Future<void> Function() body) => serialize(
    () async {
      loads++;
    },
    () async {
      events.add(id);
      await body();
    },
  );
}

void main() {
  test('runs operations in order', () async {
    final queue = _Queue();
    final gate = Completer<void>();

    final first = queue.run(1, () => gate.future);
    final second = queue.run(2, () async {});

    await Future<void>.delayed(Duration.zero);
    expect(queue.events, [1]);
    expect(queue.loads, 1);

    gate.complete();
    await Future.wait([first, second]);
    expect(queue.events, [1, 2]);
    expect(queue.loads, 2);
  });

  test('a failed operation does not poison the next one', () async {
    final queue = _Queue();

    await expectLater(
      queue.run(1, () async => throw StateError('boom')),
      throwsStateError,
    );
    await queue.run(2, () async {});

    expect(queue.events, [1, 2]);
    expect(queue.loads, 2);
  });

  test(
    'a failed load vetoes the operation without poisoning the queue',
    () async {
      final queue = _Queue();
      var ran = false;
      await expectLater(
        queue.serialize(() async => throw StateError('load failed'), () async {
          ran = true;
        }),
        throwsStateError,
      );
      expect(ran, isFalse);
      await queue.run(1, () async {});
      expect(queue.events, [1]);
    },
  );
}

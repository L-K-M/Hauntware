// The shared serial queue (SMP-13, ARC-14): bodies run one at a time in
// call order, each caller gets its own result or error, and a failure does
// not stop the next body.
import 'dart:async';

import 'package:klabautermann_core/src/util/serial_queue.dart';
import 'package:test/test.dart';

void main() {
  test('bodies run one at a time, in call order', () async {
    final queue = SerialQueue();
    final events = <String>[];

    final first = queue.run(() async {
      events.add('first start');
      await Future<void>.delayed(Duration.zero);
      events.add('first end');
    });
    final second = queue.run(() async => events.add('second'));

    await Future.wait([first, second]);

    expect(events, ['first start', 'first end', 'second']);
  });

  test('each caller gets its own result', () async {
    final queue = SerialQueue();

    expect(await queue.run(() async => 1), 1);
    expect(await queue.run(() => Future.value('two')), 'two');
  });

  test(
    "an error reaches its caller only, and the next body still runs",
    () async {
      final queue = SerialQueue();
      final events = <String>[];

      await expectLater(
        queue.run(() async => throw StateError('boom')),
        throwsStateError,
      );
      await queue.run(() async => events.add('next'));

      expect(events, ['next']);
      await queue.idle;
    },
  );

  test('idle completes once every queued body has ended', () async {
    final queue = SerialQueue();
    var ran = false;

    final pending = queue.run(() async {
      await Future<void>.delayed(Duration.zero);
      ran = true;
    });

    await queue.idle;

    expect(ran, isTrue);
    await pending;
  });

  test('idle holds nothing before a body is queued', () async {
    final queue = SerialQueue();
    var settled = false;

    unawaited(queue.idle.then((_) => settled = true));
    await Future<void>.delayed(Duration.zero);

    expect(settled, isTrue);
  });
}

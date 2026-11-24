// The engine's sync chain (ENG-5): one operation at a time, and one that
// throws costs only itself.
import 'dart:async';

import 'package:klabautermann_core/src/engine/serial_chain.dart';
import 'package:test/test.dart';

void main() {
  test('runs bodies one at a time, in the order they were added', () async {
    var tail = Future<void>.value();
    void add(Future<void> Function() body) =>
        tail = chainAfter(tail, body, onFault: (error, _) => fail('$error'));
    final log = <String>[];
    final gate = Completer<void>();
    final done = Completer<void>();

    add(() async {
      log.add('first starts');
      await gate.future;
      log.add('first ends');
    });
    add(() async {
      log.add('second');
      done.complete();
    });
    await pumpEventQueue();
    expect(log, ['first starts']);

    gate.complete();
    await done.future;
    expect(log, ['first starts', 'first ends', 'second']);
  });

  test('a body that throws is answered or reported, and the operations '
      'behind it still run', () async {
    final faults = <Object>[];
    final answered = <Object>[];
    var tail = Future<void>.value();
    void add(
      Future<void> Function() body, {
      void Function(Object error)? onError,
    }) => tail = chainAfter(
      tail,
      body,
      onError: onError,
      onFault: (error, _) => faults.add(error),
    );
    final done = Completer<void>();

    add(() async => throw StateError('unanswered'));
    add(() => throw StateError('thrown at once'), onError: answered.add);
    add(
      () async => throw StateError('answered'),
      onError: (_) => throw StateError('the answer threw'),
    );
    add(() async => done.complete());
    await done.future.timeout(const Duration(seconds: 5));

    expect(
      [for (final error in faults) '$error'],
      ['Bad state: unanswered', 'Bad state: the answer threw'],
    );
    expect(
      [for (final error in answered) '$error'],
      ['Bad state: thrown at once'],
    );
  });
}

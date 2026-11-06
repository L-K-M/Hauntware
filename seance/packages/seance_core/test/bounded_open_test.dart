import 'dart:async';

import 'package:seance_core/src/ssh/bounded_open.dart';
import 'package:test/test.dart';

void main() {
  test('returns a value that opens within the bound', () async {
    expect(
      await boundedOpen(
        pending: Future.value(7),
        timeout: const Duration(seconds: 1),
        discard: (_) {},
      ),
      7,
    );
  });

  test('discards a value that arrives after timeout exactly once', () async {
    final pending = Completer<int>();
    final discarded = <int>[];
    final opening = boundedOpen(
      pending: pending.future,
      timeout: const Duration(milliseconds: 10),
      discard: discarded.add,
    );

    await expectLater(opening, throwsA(isA<TimeoutException>()));
    pending.complete(11);
    await Future<void>.delayed(Duration.zero);
    expect(discarded, [11]);
  });

  test('owner close fails the wait and discards a late value', () async {
    final pending = Completer<int>();
    final ownerClosed = Completer<void>();
    final discarded = <int>[];
    final opening = boundedOpen(
      pending: pending.future,
      timeout: const Duration(seconds: 1),
      ownerClosed: ownerClosed.future,
      ownerClosedError: () => StateError('closed'),
      discard: discarded.add,
    );

    ownerClosed.complete();
    await expectLater(opening, throwsA(isA<StateError>()));
    pending.complete(13);
    await Future<void>.delayed(Duration.zero);
    expect(discarded, [13]);
  });

  test('observes a late error after timeout', () async {
    final pending = Completer<int>();
    final opening = boundedOpen(
      pending: pending.future,
      timeout: const Duration(milliseconds: 10),
      discard: (_) {},
    );

    await expectLater(opening, throwsA(isA<TimeoutException>()));
    pending.completeError(StateError('late'));
    await Future<void>.delayed(Duration.zero);
  });
}

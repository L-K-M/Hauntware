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

  test('successful opens share one owner-close subscription', () async {
    final rawOwner = Completer<void>();
    final ownerClosed = _TrackedFuture<void>(rawOwner.future);
    final resources = List.generate(250, (_) => Object());

    final futures = <Future<Object>>[];
    for (final resource in resources) {
      final pending = Future.value(resource);
      futures.add(
        boundedOpen(
          pending: pending,
          timeout: const Duration(seconds: 1),
          ownerClosed: ownerClosed,
          ownerClosedError: () => StateError('closed'),
          discard: (_) {},
        ),
      );
    }

    final results = await Future.wait(futures);
    for (var i = 0; i < resources.length; i++) {
      expect(results[i], same(resources[i]), reason: 'index $i');
    }

    expect(
      ownerClosed.thenRegistrations,
      1,
      reason: 'all opens should share one owner-close subscription',
    );

    final pending = Completer<Object>();
    final discarded = <Object>[];
    final remaining = boundedOpen(
      pending: pending.future,
      timeout: const Duration(seconds: 1),
      ownerClosed: ownerClosed,
      discard: discarded.add,
    );
    final closed = expectLater(remaining, throwsStateError);
    rawOwner.complete();
    await closed;
    final lateResource = Object();
    pending.complete(lateResource);
    await Future<void>.delayed(Duration.zero);
    expect(discarded, [same(lateResource)]);

    final afterClose = boundedOpen(
      pending: Future.value(Object()),
      timeout: const Duration(seconds: 1),
      ownerClosed: ownerClosed,
      discard: discarded.add,
    );
    await expectLater(afterClose, throwsStateError);
    expect(discarded, hasLength(2));
    expect(ownerClosed.thenRegistrations, 1);
  });
}

/// A Future wrapper that counts every [then] registration while delegating
/// all operations to [delegate].
class _TrackedFuture<T> implements Future<T> {
  _TrackedFuture(this.delegate);

  final Future<T> delegate;
  var thenRegistrations = 0;

  @override
  Future<R> then<R>(FutureOr<R> Function(T) onValue, {Function? onError}) {
    thenRegistrations++;
    return delegate.then(onValue, onError: onError);
  }

  @override
  Future<T> catchError(Function onError, {bool Function(Object)? test}) =>
      delegate.catchError(onError, test: test);

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      delegate.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Stream<T> asStream() => delegate.asStream();

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) =>
      delegate.whenComplete(action);
}

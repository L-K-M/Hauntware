import 'dart:async';

// A close future lives as long as its owner. Keep only one listener on it;
// per-open listeners would retain every completed resource until owner close.
// Expando keys do not prolong the future's lifetime.
final _ownerWaiters = Expando<_OwnerCloseWaiters>();

/// Awaits a resource open for no longer than [timeout] or [ownerClosed].
///
/// Futures cannot be cancelled in Dart. If the caller has already given up,
/// a value that arrives later is therefore passed to [discard] exactly once;
/// late errors are observed and ignored. [isOwnerClosed] closes the small race
/// where the owner closes immediately before a pending value is delivered.
Future<T> boundedOpen<T>({
  required Future<T> pending,
  required Duration timeout,
  required FutureOr<void> Function(T value) discard,
  Future<void>? ownerClosed,
  bool Function()? isOwnerClosed,
  Object Function()? ownerClosedError,
  String? timeoutMessage,
}) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }

  final result = Completer<T>();

  void discardValue(T value) {
    unawaited(
      Future.sync(
        () => discard(value),
      ).then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
  }

  void closeOwner() {
    if (result.isCompleted) return;
    result.completeError(
      ownerClosedError?.call() ?? StateError('The resource owner closed.'),
      StackTrace.current,
    );
  }

  final void Function()? stopWaiting;
  if (ownerClosed == null) {
    stopWaiting = null;
  } else {
    final waiters = _ownerWaiters[ownerClosed] ??= _OwnerCloseWaiters(
      ownerClosed,
    );
    stopWaiting = waiters.add(closeOwner);
  }

  pending.then<void>(
    (value) {
      if (result.isCompleted || (isOwnerClosed?.call() ?? false)) {
        if (!result.isCompleted) closeOwner();
        discardValue(value);
        return;
      }
      result.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
  );

  final timer = Timer(timeout, () {
    if (result.isCompleted) return;
    result.completeError(
      TimeoutException(timeoutMessage ?? 'Resource open timed out.', timeout),
      StackTrace.current,
    );
  });
  void settled() {
    timer.cancel();
    stopWaiting?.call();
  }

  result.future.then<void>(
    (_) => settled(),
    onError: (Object _, StackTrace __) => settled(),
  );
  return result.future;
}

/// Owner-scoped callbacks only for opens still awaiting a result. Removing a
/// settled waiter releases its completer and the resource held by that result.
final class _OwnerCloseWaiters {
  _OwnerCloseWaiters(Future<void> ownerClosed) {
    ownerClosed.then<void>(
      (_) => _close(),
      onError: (Object _, StackTrace __) => _close(),
    );
  }

  final _pending = <void Function()>{};
  var _closed = false;

  void Function() add(void Function() callback) {
    if (_closed) {
      callback();
      return () {};
    }
    _pending.add(callback);
    return () => _pending.remove(callback);
  }

  void _close() {
    _closed = true;
    final pending = _pending.toList();
    _pending.clear();
    for (final callback in pending) {
      callback();
    }
  }
}

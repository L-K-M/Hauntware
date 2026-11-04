import 'dart:async';

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

  ownerClosed?.then<void>(
    (_) => closeOwner(),
    onError: (Object _, StackTrace __) => closeOwner(),
  );

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
  result.future.then<void>(
    (_) => timer.cancel(),
    onError: (Object _, StackTrace __) => timer.cancel(),
  );
  return result.future;
}

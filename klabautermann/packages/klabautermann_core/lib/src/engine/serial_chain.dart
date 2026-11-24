import 'dart:async';

/// The new tail of a chain of operations that run one at a time, in the
/// order they were added: [body] behind [tail]. The engine's sync chain
/// (03 §4.3, D63) is built of these.
///
/// A link runs only after the one before it completed normally, so the
/// returned future completes normally whatever [body] throws: [onError]
/// answers the request that asked, and without one, or when it throws
/// itself, the error goes to [onFault]. A throw left in the chain would
/// skip every later operation and, with nothing awaiting the tail, end
/// as an unhandled error.
Future<void> chainAfter(
  Future<void> tail,
  Future<void> Function() body, {
  void Function(Object error)? onError,
  required void Function(Object error, StackTrace stack) onFault,
}) => tail.then((_) async {
  try {
    await body();
  } on Object catch (error, stack) {
    if (onError == null) return onFault(error, stack);
    try {
      onError(error);
    } on Object catch (error, stack) {
      onFault(error, stack);
    }
  }
});

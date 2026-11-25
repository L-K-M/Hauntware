/// A queue that runs one body at a time, in the order [run] was called
/// (SMP-13, ARC-14).
///
/// Each caller gets its own body's result or error. A failure does not
/// stop the queue: the tail heals before the next body runs. Every
/// hand-written copy of this pattern had to remember that healing, and one
/// forgetting it would skip every later body.
library;

import 'dart:async';

final class SerialQueue {
  Future<void> _tail = Future.value();

  /// Completes once every body queued so far has ended, failed or not; a
  /// body queued after this is read is not awaited.
  Future<void> get idle => _tail;

  /// Runs [body] once every earlier body has ended. The returned future
  /// carries [body]'s own result or error, while the queue moves on.
  Future<T> run<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

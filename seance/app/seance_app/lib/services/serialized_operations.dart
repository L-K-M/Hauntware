/// Runs operations one after another and keeps the queue usable after a
/// failed operation.
mixin SerializedOperations {
  Future<void> _operationTail = Future<void>.value();

  /// Loads committed state inside the queue before running [operation].
  Future<T> serialize<T>(
    Future<void> Function() load,
    Future<T> Function() operation,
  ) {
    final result = _operationTail.then((_) async {
      await load();
      return operation();
    });
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}

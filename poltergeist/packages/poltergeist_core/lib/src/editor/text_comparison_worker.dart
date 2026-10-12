import 'dart:async';
import 'dart:isolate';

import 'text_comparison.dart';

/// Starts comparing two texts; the compare view's test seam.
typedef TextComparisonStarter =
    TextComparisonTask Function(String left, String right);

/// One running comparison. [result] never completes with an error; after
/// [cancel] it may never complete at all, so callers drop it on cancel.
final class TextComparisonTask {
  TextComparisonTask(this.result, {required void Function() this._onCancel});

  TextComparisonTask.completed(TextComparison outcome)
    : result = Future.value(outcome),
      _onCancel = null;

  final Future<TextComparison> result;
  void Function()? _onCancel;

  /// Stops the work; calling it again, or after the result, does nothing.
  void cancel() {
    final onCancel = _onCancel;
    _onCancel = null;
    onCancel?.call();
  }
}

/// Runs [compareTexts] in a one-shot isolate that replies by exiting, so the
/// result moves back without a copy. There is no time limit: the diff's cost
/// limit bounds the work, and [TextComparisonTask.cancel] kills the worker
/// when the view closes or its documents change.
TextComparisonTask startTextComparison(String left, String right) {
  final port = RawReceivePort();
  final outcome = Completer<TextComparison>();
  Isolate? worker;
  var finished = false;

  void finish() {
    if (finished) return;
    finished = true;
    port.close();
    worker?.kill(priority: Isolate.immediate);
  }

  // The first message decides: the reply, or the error or exit notice of a
  // worker that died first.
  port.handler = (Object? message) {
    if (finished) return;
    finish();
    outcome.complete(
      message is TextComparison ? message : const TextComparisonFailed(),
    );
  };

  Isolate.spawn(
    _compareInWorker,
    _TextComparisonRequest(port.sendPort, left, right),
    errorsAreFatal: true,
    onError: port.sendPort,
    onExit: port.sendPort,
    debugName: _workerName,
  ).then(
    (isolate) {
      if (finished) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        worker = isolate;
      }
    },
    onError: (Object _) {
      if (finished) return;
      finish();
      outcome.complete(const TextComparisonFailed());
    },
  );

  return TextComparisonTask(outcome.future, onCancel: finish);
}

const _workerName = 'text-comparison';

final class _TextComparisonRequest {
  const _TextComparisonRequest(this.replyTo, this.left, this.right);

  final SendPort replyTo;
  final String left;
  final String right;
}

void _compareInWorker(_TextComparisonRequest request) =>
    Isolate.exit(request.replyTo, compareTexts(request.left, request.right));

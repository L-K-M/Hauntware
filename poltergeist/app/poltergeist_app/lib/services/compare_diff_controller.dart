import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Where the compare view's diff stands (06 §6).
enum CompareDiffPhase {
  /// A side is not loaded yet, or never will be.
  waiting,
  computing,
  ready,

  /// A side has more lines than the diff covers; nothing is marked.
  overLineCap,

  /// The worker died; nothing is marked and nothing is claimed.
  failed,
}

/// Runs one diff per pair of loaded documents, off the UI isolate, for the
/// compare view that owns it.
///
/// `SyncCompareController` notifies on every download progress tick and
/// builds fresh side states on every read, so the document pair's identity
/// is the only reliable key: asking again for the same pair does nothing.
/// A loaded side never changes, so one diff stays valid for the view's
/// controller.
final class CompareDiffController extends ChangeNotifier {
  CompareDiffController({this._start = startTextComparison});

  final TextComparisonStarter _start;
  CompareDiffPhase _phase = CompareDiffPhase.waiting;
  TextComparison? _outcome;
  BuiltInTextDocument? _left;
  BuiltInTextDocument? _right;
  TextComparisonTask? _task;
  int _generation = 0;
  bool _disposed = false;

  CompareDiffPhase get phase => _phase;

  /// The worker's answer, kept for the notice that explains it.
  TextComparison? get outcome => _outcome;

  /// The computed diff, only while [phase] is ready.
  TextComparisonComputed? get result => switch (_outcome) {
    final TextComparisonComputed computed => computed,
    _ => null,
  };

  BuiltInTextDocument? get left => _left;
  BuiltInTextDocument? get right => _right;

  /// Compares [left] with [right] once both are loaded, replacing any diff
  /// of another pair.
  void compare(BuiltInTextDocument? left, BuiltInTextDocument? right) {
    if (_disposed) return;
    if (identical(left, _left) && identical(right, _right)) return;

    _task?.cancel();
    _task = null;
    final generation = ++_generation;
    _left = left;
    _right = right;
    _outcome = null;
    if (left == null || right == null) {
      _phase = CompareDiffPhase.waiting;
      notifyListeners();
      return;
    }

    _phase = CompareDiffPhase.computing;
    final task = _task = _start(left.text, right.text);
    notifyListeners();
    task.result.then((outcome) {
      if (_disposed || generation != _generation) return;
      _task = null;
      _outcome = outcome;
      _phase = switch (outcome) {
        TextComparisonComputed() => CompareDiffPhase.ready,
        TextComparisonOverLineCap() => CompareDiffPhase.overLineCap,
        TextComparisonFailed() => CompareDiffPhase.failed,
      };
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _task?.cancel();
    _task = null;
    super.dispose();
  }
}

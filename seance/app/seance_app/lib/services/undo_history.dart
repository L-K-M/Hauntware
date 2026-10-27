import 'package:flutter/foundation.dart';

/// One change Edit ▸ Undo can take back. [name] completes the menu's
/// "Undo …" and "Redo …"; [undo] and [redo] apply its two directions.
@immutable
final class UndoableChange {
  const UndoableChange({
    required this.name,
    required this.undo,
    required this.redo,
  });

  final String name;
  final Future<void> Function() undo;
  final Future<void> Function() redo;
}

/// A step a change declines to take right now, for a reason the user can
/// clear ("close its tabs first"): the change stays where it was, so the
/// same Undo works once they have.
final class UndoDeclined implements Exception {
  const UndoDeclined(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's own undo history: what Edit ▸ Undo and Redo do outside text
/// fields, which keep their own. Holds the user's changes to snippets and
/// the server list, newest last, and only for this run of the app.
final class AppUndoHistory extends ChangeNotifier {
  AppUndoHistory({this.limit = 50});

  /// The most changes kept; the oldest go first.
  final int limit;

  final List<UndoableChange> _done = [];
  final List<UndoableChange> _undone = [];

  /// A change being undone or redone, during which neither applies.
  bool _stepping = false;

  /// The change Undo would take back, or null when there is none.
  String? get undoName => _stepping ? null : _done.lastOrNull?.name;

  /// The change Redo would apply again, or null when there is none.
  String? get redoName => _stepping ? null : _undone.lastOrNull?.name;

  /// Whether [change] is the one Undo would take back now: a notice
  /// offering to undo one change must not undo another.
  bool isNextUndo(UndoableChange change) =>
      !_stepping && identical(_done.lastOrNull, change);

  /// Records a change the user just made. Anything undone before it can
  /// no longer be redone, as everywhere else.
  void record(UndoableChange change) {
    _done.add(change);
    if (_done.length > limit) _done.removeAt(0);
    _undone.clear();
    notifyListeners();
  }

  Future<void> undo() => _step(_done, _undone, (change) => change.undo());

  Future<void> redo() => _step(_undone, _done, (change) => change.redo());

  /// Applies the newest change in [from], moving it to [to] first, so a
  /// change recorded while it applies lands after it. One that throws
  /// leaves the history and the error passes on, since a change that did
  /// not apply cannot be stepped back over; one that is [UndoDeclined]
  /// goes back where it was.
  Future<void> _step(
    List<UndoableChange> from,
    List<UndoableChange> to,
    Future<void> Function(UndoableChange change) apply,
  ) async {
    if (_stepping || from.isEmpty) return;
    final change = from.removeLast();
    to.add(change);
    _stepping = true;
    notifyListeners();
    try {
      await apply(change);
    } on UndoDeclined {
      to.remove(change);
      from.add(change);
      rethrow;
    } catch (_) {
      to.remove(change);
      rethrow;
    } finally {
      _stepping = false;
      notifyListeners();
    }
  }
}

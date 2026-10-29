import 'dart:math' show min;

import 'package:flutter/foundation.dart';

/// One change the app's Undo can take back. [name] says what it was in
/// the notice ("Delete snippet undone"); [undo] and [redo] apply its two
/// directions.
@immutable
final class GhostUndoableChange {
  const GhostUndoableChange({
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
final class GhostUndoDeclined implements Exception {
  const GhostUndoDeclined(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An app's own undo history: what the Undo and Redo shortcuts do outside
/// text fields, which keep their own. Holds the user's changes to the
/// app's data (a deleted snippet, a pinned server), newest last, and only
/// for this run of the app. Hosts word the notices and bind the keys.
final class GhostUndoHistory extends ChangeNotifier {
  GhostUndoHistory({this.limit = 50});

  /// The most changes kept; the oldest go first.
  final int limit;

  final List<GhostUndoableChange> _done = [];
  final List<GhostUndoableChange> _undone = [];

  /// A change being undone or redone, during which neither applies.
  bool _stepping = false;

  /// Counts [record] calls, so a step can tell one happened while it
  /// applied.
  int _recorded = 0;

  /// The change Undo would take back, or null when there is none.
  String? get undoName => _stepping ? null : _done.lastOrNull?.name;

  /// The change Redo would apply again, or null when there is none.
  String? get redoName => _stepping ? null : _undone.lastOrNull?.name;

  /// Whether [change] is the one Undo would take back now: a notice
  /// offering to undo one change must not undo another.
  bool isNextUndo(GhostUndoableChange change) =>
      !_stepping && identical(_done.lastOrNull, change);

  /// Records a change the user just made. Anything undone before it can
  /// no longer be redone, as everywhere else.
  void record(GhostUndoableChange change) {
    _recorded++;
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
  /// not apply cannot be stepped back over; one that is [GhostUndoDeclined]
  /// goes back where it was: under any change recorded meanwhile, and not
  /// into a redo list that such a change ended.
  Future<void> _step(
    List<GhostUndoableChange> from,
    List<GhostUndoableChange> to,
    Future<void> Function(GhostUndoableChange change) apply,
  ) async {
    if (_stepping || from.isEmpty) return;
    final change = from.removeLast();
    final slot = from.length;
    final recorded = _recorded;
    to.add(change);
    _stepping = true;
    notifyListeners();
    try {
      await apply(change);
    } on GhostUndoDeclined {
      to.remove(change);
      final redoEnded = identical(from, _undone) && _recorded != recorded;
      if (!redoEnded) from.insert(min(slot, from.length), change);
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

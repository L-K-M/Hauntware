import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  GhostUndoableChange change(String name, List<String> log) =>
      GhostUndoableChange(
        name: name,
        undo: () async => log.add('undo $name'),
        redo: () async => log.add('redo $name'),
      );

  test('undo and redo walk the history and name the next step', () async {
    final log = <String>[];
    final history = GhostUndoHistory()
      ..record(change('Delete snippet', log))
      ..record(change('Pin to top', log));
    expect(history.undoName, 'Pin to top');
    expect(history.redoName, isNull);

    await history.undo();
    expect(log, ['undo Pin to top']);
    expect(history.undoName, 'Delete snippet');
    expect(history.redoName, 'Pin to top');

    await history.redo();
    expect(log, ['undo Pin to top', 'redo Pin to top']);
    expect(history.undoName, 'Pin to top');
  });

  test('a new change ends what could be redone', () async {
    final log = <String>[];
    final history = GhostUndoHistory()..record(change('Edit snippet', log));
    await history.undo();
    expect(history.redoName, 'Edit snippet');
    history.record(change('New snippet', log));
    expect(history.redoName, isNull);
    expect(history.undoName, 'New snippet');
  });

  test('the oldest changes fall off past the limit', () async {
    final log = <String>[];
    final history = GhostUndoHistory(limit: 2)
      ..record(change('one', log))
      ..record(change('two', log))
      ..record(change('three', log));
    await history.undo();
    await history.undo();
    expect(history.undoName, isNull);
    expect(log, ['undo three', 'undo two']);
  });

  test('a change that fails to apply leaves the history', () async {
    final history = GhostUndoHistory()
      ..record(
        GhostUndoableChange(
          name: 'Duplicate server',
          undo: () async => throw StateError('vault locked'),
          redo: () async {},
        ),
      );
    await expectLater(history.undo(), throwsStateError);
    expect(history.undoName, isNull);
    expect(history.redoName, isNull);
  });

  test('a declined step stays where it was, ready to try again', () async {
    var tries = 0;
    final history = GhostUndoHistory()
      ..record(
        GhostUndoableChange(
          name: 'Duplicate server',
          undo: () async {
            if (tries++ == 0) throw const GhostUndoDeclined('close its tabs');
          },
          redo: () async {},
        ),
      );
    await expectLater(history.undo(), throwsA(isA<GhostUndoDeclined>()));
    expect(history.undoName, 'Duplicate server');
    await history.undo();
    expect(history.undoName, isNull);
    expect(history.redoName, 'Duplicate server');
  });

  test('a change recorded while a step applies lands after it', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final history = GhostUndoHistory()
      ..record(
        GhostUndoableChange(
          name: 'Delete snippet',
          undo: () => gate.future,
          redo: () async {},
        ),
      );
    final undoing = history.undo();
    history.record(change('Pin to top', log));
    gate.complete();
    await undoing;
    // The pin came last, and it ended what could be redone.
    expect(history.undoName, 'Pin to top');
    expect(history.redoName, isNull);
  });

  test('a notice undoes only the change it names', () {
    final log = <String>[];
    final first = change('Delete snippet', log);
    final history = GhostUndoHistory()..record(first);
    expect(history.isNextUndo(first), isTrue);
    history.record(change('Pin to top', log));
    expect(history.isNextUndo(first), isFalse);
  });

  test(
    'a change recorded while an undo is declined stays the newest',
    () async {
      final gate = Completer<void>();
      final history = GhostUndoHistory()
        ..record(
          GhostUndoableChange(
            name: 'Duplicate server',
            undo: () async {
              await gate.future;
              throw const GhostUndoDeclined('Close its tabs first.');
            },
            redo: () async {},
          ),
        );

      final undoing = history.undo();
      // The user deletes a snippet while the undo is still deciding.
      history.record(change('Delete snippet', []));
      gate.complete();
      await expectLater(undoing, throwsA(isA<GhostUndoDeclined>()));

      expect(history.undoName, 'Delete snippet');
      await history.undo();
      expect(history.undoName, 'Duplicate server');
    },
  );
}

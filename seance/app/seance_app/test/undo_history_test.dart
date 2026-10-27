import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/undo_history.dart';

void main() {
  UndoableChange change(String name, List<String> log) => UndoableChange(
    name: name,
    undo: () async => log.add('undo $name'),
    redo: () async => log.add('redo $name'),
  );

  test('undo and redo walk the history and name the next step', () async {
    final log = <String>[];
    final history = AppUndoHistory()
      ..record(change('Delete Snippet', log))
      ..record(change('Pin to Top', log));
    expect(history.undoName, 'Pin to Top');
    expect(history.redoName, isNull);

    await history.undo();
    expect(log, ['undo Pin to Top']);
    expect(history.undoName, 'Delete Snippet');
    expect(history.redoName, 'Pin to Top');

    await history.redo();
    expect(log, ['undo Pin to Top', 'redo Pin to Top']);
    expect(history.undoName, 'Pin to Top');
  });

  test('a new change ends what could be redone', () async {
    final log = <String>[];
    final history = AppUndoHistory()..record(change('Edit Snippet', log));
    await history.undo();
    expect(history.redoName, 'Edit Snippet');
    history.record(change('New Snippet', log));
    expect(history.redoName, isNull);
    expect(history.undoName, 'New Snippet');
  });

  test('the oldest changes fall off past the limit', () async {
    final log = <String>[];
    final history = AppUndoHistory(limit: 2)
      ..record(change('one', log))
      ..record(change('two', log))
      ..record(change('three', log));
    await history.undo();
    await history.undo();
    expect(history.undoName, isNull);
    expect(log, ['undo three', 'undo two']);
  });

  test('a change that fails to apply leaves the history', () async {
    final history = AppUndoHistory()
      ..record(
        UndoableChange(
          name: 'Duplicate Server',
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
    final history = AppUndoHistory()
      ..record(
        UndoableChange(
          name: 'Duplicate Server',
          undo: () async {
            if (tries++ == 0) throw const UndoDeclined('close its tabs');
          },
          redo: () async {},
        ),
      );
    await expectLater(history.undo(), throwsA(isA<UndoDeclined>()));
    expect(history.undoName, 'Duplicate Server');
    await history.undo();
    expect(history.undoName, isNull);
    expect(history.redoName, 'Duplicate Server');
  });

  test('a change recorded while a step applies lands after it', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final history = AppUndoHistory()
      ..record(
        UndoableChange(
          name: 'Delete Snippet',
          undo: () => gate.future,
          redo: () async {},
        ),
      );
    final undoing = history.undo();
    history.record(change('Pin to Top', log));
    gate.complete();
    await undoing;
    // The pin came last, and it ended what could be redone.
    expect(history.undoName, 'Pin to Top');
    expect(history.redoName, isNull);
  });

  test('a notice undoes only the change it names', () {
    final log = <String>[];
    final first = change('Delete Snippet', log);
    final history = AppUndoHistory()..record(first);
    expect(history.isNextUndo(first), isTrue);
    history.record(change('Pin to Top', log));
    expect(history.isNextUndo(first), isFalse);
  });
}

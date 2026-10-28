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
    final history = AppUndoHistory()..record(change('Edit snippet', log));
    await history.undo();
    expect(history.redoName, 'Edit snippet');
    history.record(change('New snippet', log));
    expect(history.redoName, isNull);
    expect(history.undoName, 'New snippet');
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
    final history = AppUndoHistory()
      ..record(
        UndoableChange(
          name: 'Duplicate server',
          undo: () async {
            if (tries++ == 0) throw const UndoDeclined('close its tabs');
          },
          redo: () async {},
        ),
      );
    await expectLater(history.undo(), throwsA(isA<UndoDeclined>()));
    expect(history.undoName, 'Duplicate server');
    await history.undo();
    expect(history.undoName, isNull);
    expect(history.redoName, 'Duplicate server');
  });

  test('a change recorded while a step applies lands after it', () async {
    final log = <String>[];
    final gate = Completer<void>();
    final history = AppUndoHistory()
      ..record(
        UndoableChange(
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
    final history = AppUndoHistory()..record(first);
    expect(history.isNextUndo(first), isTrue);
    history.record(change('Pin to top', log));
    expect(history.isNextUndo(first), isFalse);
  });
}

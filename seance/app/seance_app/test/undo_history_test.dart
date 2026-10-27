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
}

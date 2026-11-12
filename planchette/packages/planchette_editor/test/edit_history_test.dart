import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/src/edit_history.dart';

void main() {
  final start = DateTime(2026);
  TextSelection caret(int offset) => TextSelection.collapsed(offset: offset);

  /// Types [chars] one at a time at [at], [gap] apart, as the field would
  /// report them; returns the text and the time after the last keystroke.
  (String, DateTime) type(
    EditHistory history,
    String text,
    int at,
    String chars, {
    required DateTime from,
    Duration gap = const Duration(milliseconds: 100),
  }) {
    var now = from;
    for (final char in chars.split('')) {
      final next = text.replaceRange(at, at, char);
      history.record(
        before: text,
        after: next,
        selectionBefore: caret(at),
        selectionAfter: caret(at + 1),
        origin: EditOrigin.typing,
        at: now,
      );
      text = next;
      at++;
      now = now.add(gap);
    }
    return (text, now);
  }

  List<String> undoAll(EditHistory history, String text) {
    final seen = <String>[];
    for (var value = history.undo(text); value != null;) {
      text = value.text;
      seen.add(text);
      value = history.undo(text);
    }
    return seen;
  }

  group('diffs', () {
    test('undo and redo round-trip random edits exactly', () {
      final random = Random(7);
      const alphabet = 'ab \n😀é';
      String word(int length) => String.fromCharCodes([
        for (var i = 0; i < length; i++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);

      final history = EditHistory();
      final texts = <String>[word(20)];
      var now = start;
      for (var i = 0; i < 300; i++) {
        final before = texts.last;
        final from = random.nextInt(before.length + 1);
        final to = from + random.nextInt(before.length - from + 1);
        final after = before.replaceRange(from, to, word(random.nextInt(4)));
        history.record(
          before: before,
          after: after,
          selectionBefore: caret(from),
          selectionAfter: caret(from),
          origin: i.isEven ? EditOrigin.typing : EditOrigin.command,
          at: now,
        );
        if (after != before) texts.add(after);
        now = now.add(const Duration(seconds: 1));
      }

      // Each step was its own (a second apart), so undo walks back
      // through every distinct text and redo forward again.
      var text = texts.last;
      for (final expected in texts.reversed.skip(1)) {
        text = history.undo(text)!.text;
        expect(text, expected);
      }
      expect(history.undo(text), isNull);
      for (final expected in texts.skip(1)) {
        text = history.redo(text)!.text;
        expect(text, expected);
      }
      expect(history.redo(text), isNull);
    });

    test('equal texts record nothing', () {
      final history = EditHistory()
        ..record(
          before: 'same',
          after: 'same',
          selectionBefore: caret(0),
          selectionAfter: caret(4),
          origin: EditOrigin.typing,
          at: start,
        );
      expect(history.canUndo, isFalse);
    });

    test('a step stores the change, not the document', () {
      final document = 'x' * 100000;
      final history = EditHistory();
      type(history, document, 500, 'hello', from: start);
      expect(history.storedBytes, lessThan(200));
    });

    test('undo restores the selection before, redo the one after', () {
      final history = EditHistory()
        ..record(
          before: 'one two',
          after: 'one 2',
          selectionBefore: const TextSelection(baseOffset: 4, extentOffset: 7),
          selectionAfter: caret(5),
          origin: EditOrigin.command,
          at: start,
        );
      final undone = history.undo('one 2')!;
      expect(undone.text, 'one two');
      expect(
        undone.selection,
        const TextSelection(baseOffset: 4, extentOffset: 7),
      );
      expect(history.redo('one two')!.selection, caret(5));
    });

    test('a text the history did not record clears it instead', () {
      final history = EditHistory();
      type(history, '', 0, 'abc', from: start);
      expect(history.undo('something else'), isNull);
      expect(history.canUndo, isFalse);
      expect(history.storedBytes, 0);
    });
  });

  group('typing', () {
    test('a word typed without pausing is one step', () {
      final history = EditHistory();
      final (text, _) = type(history, '', 0, 'hello', from: start);
      expect(history.undoDepth, 1);
      expect(undoAll(history, text), ['']);
    });

    test('a pause as long as the typing pause starts a new step', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      (text, now) = type(
        history,
        text,
        2,
        'cd',
        from: now.add(EditHistory.defaultTypingPause),
      );
      expect(undoAll(history, text), ['ab', '']);
    });

    test('a new word after whitespace starts a new step', () {
      final history = EditHistory();
      final (text, _) = type(history, '', 0, 'hi there you', from: start);
      expect(undoAll(history, text), ['hi there ', 'hi ', '']);
    });

    test('a caret move starts a new step', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      // The caret went back to the start before the next keystroke.
      (text, now) = type(history, text, 0, 'xy', from: now);
      expect(text, 'xyab');
      expect(undoAll(history, text), ['ab', '']);
    });

    test('backspaces merge, and do not merge with inserts', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'abcd', from: start);
      for (var at = 4; at > 2; at--) {
        final next = text.replaceRange(at - 1, at, '');
        history.record(
          before: text,
          after: next,
          selectionBefore: caret(at),
          selectionAfter: caret(at - 1),
          origin: EditOrigin.typing,
          at: now,
        );
        text = next;
        now = now.add(const Duration(milliseconds: 100));
      }
      expect(text, 'ab');
      expect(undoAll(history, text), ['abcd', '']);
    });

    test('forward deletes at one place merge', () {
      final history = EditHistory();
      var text = 'abcdef';
      for (var i = 0; i < 3; i++) {
        final next = text.replaceRange(1, 2, '');
        history.record(
          before: text,
          after: next,
          selectionBefore: caret(1),
          selectionAfter: caret(1),
          origin: EditOrigin.typing,
          at: start.add(Duration(milliseconds: 100 * i)),
        );
        text = next;
      }
      expect(text, 'aef');
      expect(undoAll(history, text), ['abcdef']);
    });

    test('typing over a selection and on is one step', () {
      final history = EditHistory()
        ..record(
          before: 'say old',
          after: 'say n',
          selectionBefore: const TextSelection(baseOffset: 4, extentOffset: 7),
          selectionAfter: caret(5),
          origin: EditOrigin.typing,
          at: start,
        );
      final (text, _) = type(
        history,
        'say n',
        5,
        'ew',
        from: start.add(const Duration(milliseconds: 100)),
      );
      expect(text, 'say new');
      expect(undoAll(history, text), ['say old']);
    });

    test('a command write is always a step of its own', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      history.record(
        before: text,
        after: '${text}c',
        selectionBefore: caret(2),
        selectionAfter: caret(3),
        origin: EditOrigin.command,
        at: now,
      );
      text = '${text}c';
      (text, now) = type(history, text, 3, 'de', from: now);
      expect(undoAll(history, text), ['abc', 'ab', '']);
    });

    test('a multi-character change is a step of its own', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      history.record(
        before: text,
        after: '${text}pasted',
        selectionBefore: caret(2),
        selectionAfter: caret(8),
        origin: EditOrigin.typing,
        at: now,
      );
      text = '${text}pasted';
      (text, now) = type(history, text, 8, 'z', from: now);
      expect(undoAll(history, text), ['abpasted', 'ab', '']);
    });

    test('undo ends the step typing would continue', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      (text, now) = type(history, text, 2, 'c', from: now);
      text = history.undo(text)!.text;
      expect(text, '');
      (text, now) = type(history, text, 0, 'x', from: now);
      (text, now) = type(history, text, 1, 'y', from: now);
      expect(undoAll(history, text), ['']);
    });
  });

  group('redo', () {
    test('a new edit clears redo', () {
      final history = EditHistory();
      var (text, now) = type(history, '', 0, 'ab', from: start);
      text = history.undo(text)!.text;
      expect(history.canRedo, isTrue);
      type(history, text, 0, 'x', from: now.add(const Duration(seconds: 1)));
      expect(history.canRedo, isFalse);
      expect(history.redo('x'), isNull);
    });
  });

  group('budget', () {
    test('passing the budget drops the oldest steps first', () {
      final history = EditHistory(budgetBytes: 2000);
      var text = '';
      var now = start;
      final texts = <String>[text];
      for (var i = 0; i < 50; i++) {
        final next = '$text${'$i'.padLeft(40, '-')}';
        history.record(
          before: text,
          after: next,
          selectionBefore: caret(text.length),
          selectionAfter: caret(next.length),
          origin: EditOrigin.command,
          at: now,
        );
        text = next;
        texts.add(text);
        now = now.add(const Duration(seconds: 1));
      }
      expect(history.storedBytes, lessThanOrEqualTo(2000));
      // The newest steps survive, in order; the oldest are gone.
      final undone = undoAll(history, text);
      expect(undone, isNotEmpty);
      expect(undone.length, lessThan(50));
      expect(undone, texts.reversed.skip(1).take(undone.length).toList());
      expect(undone.last, isNot(''));
    });

    test('the newest step stays even when it alone is over budget', () {
      final history = EditHistory(budgetBytes: 100);
      final big = 'y' * 1000;
      history.record(
        before: 'x',
        after: big,
        selectionBefore: caret(0),
        selectionAfter: caret(1000),
        origin: EditOrigin.command,
        at: start,
      );
      expect(history.undoDepth, 1);
      expect(history.undo(big)!.text, 'x');
    });

    test('clear forgets everything', () {
      final history = EditHistory();
      final (text, _) = type(history, '', 0, 'abc', from: start);
      history.undo(text);
      history.clear();
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
      expect(history.storedBytes, 0);
    });
  });
}

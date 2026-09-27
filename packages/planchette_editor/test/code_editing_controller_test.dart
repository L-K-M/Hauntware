import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

CodeEditingController editing(String text, [int base = 0, int? extent]) =>
    CodeEditingController()
      ..value = TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: base,
          extentOffset: extent ?? base,
        ),
      );

void main() {
  group('duplicateLines', () {
    test('duplicates the caret line below and selects the copy', () {
      final c = editing('one\ntwo\nthree\n', 6);
      c.duplicateLines();
      expect(c.text, 'one\ntwo\ntwo\nthree\n');
      expect(c.selection, const TextSelection.collapsed(offset: 10));
    });

    test('duplicates every line a selection touches', () {
      final c = editing('one\ntwo\nthree\n', 1, 9);
      c.duplicateLines();
      expect(c.text, 'one\ntwo\nthree\none\ntwo\nthree\n');
      expect(
        c.selection,
        const TextSelection(baseOffset: 15, extentOffset: 23),
      );
    });

    test('inserts the missing newline when duplicating the final line', () {
      final c = editing('one\nlast', 5);
      c.duplicateLines();
      expect(c.text, 'one\nlast\nlast');
      expect(c.selection, const TextSelection.collapsed(offset: 10));
    });

    test('does nothing on an empty document', () {
      final c = editing('');
      c.duplicateLines();
      expect(c.text, '');
    });
  });

  group('moveLines', () {
    test('moves the caret line up and down', () {
      final c = editing('one\ntwo\nthree\n', 5);
      c.moveLines(up: true);
      expect(c.text, 'two\none\nthree\n');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
      c.moveLines(up: false);
      expect(c.text, 'one\ntwo\nthree\n');
      expect(c.selection, const TextSelection.collapsed(offset: 5));
    });

    test('moves a multi-line selection as a block', () {
      final c = editing('a\nb\nc\nd\n', 3, 6);
      c.moveLines(up: false);
      expect(c.text, 'a\nd\nb\nc\n');
      expect(
        c.selection,
        const TextSelection(baseOffset: 5, extentOffset: 8),
      );
    });

    test('moves the unterminated final line up', () {
      final c = editing('a\nb\nlast', 7);
      c.moveLines(up: true);
      expect(c.text, 'a\nlast\nb');
      expect(c.selection, const TextSelection.collapsed(offset: 5));
    });

    test('moves a line down onto the unterminated final line', () {
      final c = editing('a\nb\nlast', 3);
      c.moveLines(up: false);
      expect(c.text, 'a\nlast\nb');
      expect(c.selection, const TextSelection.collapsed(offset: 8));
    });

    test('is a no-op at the document boundary', () {
      final c = editing('a\nb', 0);
      c.moveLines(up: true);
      expect(c.text, 'a\nb');
      c.moveLines(up: false);
      expect(c.text, 'b\na');
      c.moveLines(up: false);
      expect(c.text, 'b\na');
    });
  });

  group('deleteLines', () {
    test('deletes the caret line', () {
      final c = editing('one\ntwo\nthree\n', 5);
      c.deleteLines();
      expect(c.text, 'one\nthree\n');
      expect(c.selection, const TextSelection.collapsed(offset: 4));
    });

    test('deletes the selection lines without a dangling newline', () {
      final c = editing('a\nb\nlast', 3, 7);
      c.deleteLines();
      expect(c.text, 'a');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
    });

    test('deleting every line empties the document', () {
      final c = editing('a\nb', 0, 4);
      c.deleteLines();
      expect(c.text, '');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
    });
  });

  group('joinLines', () {
    test('joins the caret line with the next, caret at the join', () {
      final c = editing('one\n   two\nthree', 2);
      c.joinLines();
      expect(c.text, 'one two\nthree');
      expect(c.selection, const TextSelection.collapsed(offset: 3));
    });

    test('joins all selected lines, skipping blank ones', () {
      final c = editing('a\n\n  b\nend', 0, 7);
      c.joinLines();
      expect(c.text, 'a b\nend');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
    });

    test('is a no-op on the last line', () {
      final c = editing('a\nb', 3);
      c.joinLines();
      expect(c.text, 'a\nb');
    });
  });
}

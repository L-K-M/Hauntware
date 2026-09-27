import 'package:test/test.dart';

import 'package:planchette_core/planchette_core.dart';

void main() {
  group('insertIndent', () {
    test('a caret at the line start opens one indent', () {
      final edit = insertIndent(
        'abc',
        start: 0,
        end: 0,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, '    abc');
      expect(edit.start, 4);
      expect(edit.end, 4);
    });

    test('a caret after code pads to the next tab stop', () {
      final edit = insertIndent(
        'abc',
        start: 2,
        end: 2,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, 'ab  c');
      expect(edit.start, 4);
    });

    test('a caret already at a tab stop takes a whole further stop', () {
      final edit = insertIndent(
        'abcd',
        start: 4,
        end: 4,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, 'abcd    ');
      expect(edit.start, 8);
    });

    test('a caret after a leading tab is still inside the indentation', () {
      final edit = insertIndent(
        '\t',
        start: 1,
        end: 1,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, '\t    ');
      expect(edit.start, 5);
    });

    test('a tab before the caret counts as a whole stop of columns', () {
      final edit = insertIndent(
        '\tab',
        start: 2,
        end: 2,
        tabWidth: 4,
        insertSpaces: true,
      );

      // The tab put the caret at column 4, so the next stop is column 8. The
      // padding lands at the caret so the code around it does not move.
      expect(edit.text, '\ta   b');
      expect(edit.start, 5);
    });

    test('insertSpaces false emits a literal tab', () {
      final edit = insertIndent(
        'abc',
        start: 0,
        end: 0,
        tabWidth: 4,
        insertSpaces: false,
      );

      expect(edit.text, '\tabc');
      expect(edit.start, 1);
    });

    test('a single-line selection is replaced by one indent', () {
      final edit = insertIndent(
        'abc',
        start: 1,
        end: 2,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, 'a    c');
      expect(edit.start, 5);
      expect(edit.end, 5);
    });

    test('a multi-line selection indents every line it touches', () {
      final edit = insertIndent(
        'one\ntwo\nthree',
        start: 1,
        end: 6,
        tabWidth: 2,
        insertSpaces: true,
      );

      expect(edit.text, '  one\n  two\nthree');
      // The selection still covers the same characters: the 'n' of one
      // through the 'w' of two, both of which moved right by two.
      expect(edit.start, 3);
      expect(edit.end, 10);
    });

    test('a selection ending on a line start does not indent that line', () {
      final edit = insertIndent(
        'one\ntwo',
        start: 0,
        end: 4,
        tabWidth: 2,
        insertSpaces: true,
      );

      expect(edit.text, '  one\ntwo');
    });

    test('a caret on an empty document opens one indent', () {
      final edit = insertIndent(
        '',
        start: 0,
        end: 0,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, '    ');
      expect(edit.start, 4);
    });

    test('a caret inside the indentation adds a whole indent', () {
      final edit = insertIndent(
        '  ab',
        start: 2,
        end: 2,
        tabWidth: 4,
        insertSpaces: true,
      );

      expect(edit.text, '      ab');
      expect(edit.start, 6);
    });

    test('rejects an out-of-range selection instead of clamping silently', () {
      expect(
        () => insertIndent(
          'abc',
          start: 0,
          end: 9,
          tabWidth: 4,
          insertSpaces: true,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a reversed selection', () {
      expect(
        () => insertIndent(
          'abc',
          start: 2,
          end: 1,
          tabWidth: 4,
          insertSpaces: true,
        ),
        throwsArgumentError,
      );
    });
  });

  group('removeIndent', () {
    test('removes up to one tab stop of leading whitespace', () {
      final edit = removeIndent('        one', start: 8, end: 11, tabWidth: 4);

      expect(edit.text, '    one');
      expect(edit.start, 4);
      expect(edit.end, 7);
    });

    test('removes a leading tab whole', () {
      final edit = removeIndent('\t\tone', start: 2, end: 5, tabWidth: 4);

      expect(edit.text, '\tone');
      expect(edit.start, 1);
      expect(edit.end, 4);
    });

    test('a line with no leading whitespace is left alone', () {
      final edit = removeIndent('one', start: 0, end: 3, tabWidth: 4);

      expect(edit.text, 'one');
      expect(edit.start, 0);
      expect(edit.end, 3);
    });

    test('dedents every touched line, taking at most one stop each', () {
      final edit = removeIndent(
        '  one\ntwo\n      three',
        start: 0,
        end: 21,
        tabWidth: 4,
      );

      expect(edit.text, 'one\ntwo\n  three');
    });

    test('a selection on a later line is unaffected by an earlier one', () {
      final edit = removeIndent(
        '    one\n    two',
        start: 8,
        end: 14,
        tabWidth: 4,
      );

      expect(edit.text, '    one\ntwo');
      // Only the second line was touched: the start stays at that line's first
      // character and the end follows the 'w' it still covers.
      expect(edit.start, 8);
      expect(edit.end, 10);
    });

    test('an endpoint inside removed indentation collapses to the line', () {
      final edit = removeIndent('    one', start: 2, end: 6, tabWidth: 4);

      // '  on' survives as 'on'; only the start had to collapse.
      expect(edit.text, 'one');
      expect(edit.start, 0);
      expect(edit.end, 2);
    });

    test('rejects an out-of-range selection', () {
      expect(
        () => removeIndent('abc', start: 0, end: 9, tabWidth: 4),
        throwsArgumentError,
      );
    });
  });

  group('measureIndentation', () {
    test('reports the deepest indentation in characters', () {
      expect(measureIndentation('a\n    b\n        c').width, 8);
    });

    test('a tab-indented file reports tabs', () {
      expect(measureIndentation('a\n\tb\n\t\tc').usesTabs, isTrue);
    });

    test('a space-indented file reports spaces', () {
      expect(measureIndentation('a\n  b\n    c').usesTabs, isFalse);
    });

    test('a file with no indentation reports none', () {
      expect(measureIndentation('a\nb\nc').width, 0);
    });

    test('stops sampling once the budget is spent', () {
      final text = List.generate(1000, (i) => 'line').join('\n');
      expect(measureIndentation(text, maximumLines: 10).width, 0);
    });

    test('a blank line does not count as indentation', () {
      expect(measureIndentation('a\n     \n  b').width, 2);
    });
  });
}

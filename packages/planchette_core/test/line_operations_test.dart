import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Writes a buffer with its selection marked: `[` is the base and `]` the
/// extent, or `|` a caret. `a[bc]d` selects `bc` forwards, `a]bc[d`
/// backwards.
String marked(LineEdit? edit) {
  if (edit == null) return 'null';
  final marks = edit.selectionBase == edit.selectionExtent
      ? {edit.selectionBase: '|'}
      : {edit.selectionBase: '[', edit.selectionExtent: ']'};
  final out = StringBuffer();
  for (var i = 0; i <= edit.text.length; i++) {
    out.write(marks[i] ?? '');
    if (i < edit.text.length) out.write(edit.text[i]);
  }
  return out.toString();
}

/// Runs [command] on a marked buffer (see [marked]) and returns the marked
/// result.
String run(
  LineEdit? Function(String text, int base, int extent) command,
  String input,
) {
  final caret = input.indexOf('|');
  final int base;
  final int extent;
  String text;
  if (caret >= 0) {
    text = input.replaceFirst('|', '');
    base = extent = caret;
  } else {
    final open = input.indexOf('[');
    final close = input.indexOf(']');
    text = input.replaceFirst('[', '').replaceFirst(']', '');
    base = open < close ? open : open - 1;
    extent = close < open ? close : close - 1;
  }
  return marked(command(text, base, extent));
}

void main() {
  group('duplicateLines', () {
    test('copies the caret line below and moves onto the copy', () {
      expect(run(duplicateLines, 'a\nb|c\nd'), 'a\nbc\nb|c\nd');
    });

    test('copies the last line without a trailing newline', () {
      expect(run(duplicateLines, 'a\nb|'), 'a\nb\nb|');
    });

    test('copies an empty buffer as one more empty line', () {
      expect(run(duplicateLines, '|'), '\n|');
    });

    test('copies every touched line and keeps the selection shape', () {
      expect(run(duplicateLines, 'a[b\nc]d\ne'), 'ab\ncd\na[b\nc]d\ne');
      expect(run(duplicateLines, 'a]b\nc[d\ne'), 'ab\ncd\na]b\nc[d\ne');
    });

    test('ignores the line a selection only reaches the start of', () {
      expect(run(duplicateLines, '[a\n]b'), 'a\n[a\n]b');
    });
  });

  group('moveLines', () {
    LineEdit? up(String t, int b, int e) =>
        moveLines(t, b, e, LineDirection.up);
    LineEdit? down(String t, int b, int e) =>
        moveLines(t, b, e, LineDirection.down);

    test('swaps the caret line with its neighbour', () {
      expect(run(up, 'a\nb|c\nd'), 'b|c\na\nd');
      expect(run(down, 'a\nb|c\nd'), 'a\nd\nb|c');
    });

    test('does nothing at the edges of the buffer', () {
      expect(run(up, 'a|\nb'), 'null');
      expect(run(down, 'a\nb|'), 'null');
      expect(run(up, '|'), 'null');
    });

    test('moves a block of touched lines and keeps its selection', () {
      expect(run(up, 'a\nb[c\nd]e\nf'), 'b[c\nd]e\na\nf');
      expect(run(down, 'a\nb]c\nd[e\nf'), 'a\nf\nb]c\nd[e');
    });

    test('moves whole-line selections without the next line', () {
      expect(run(up, 'a\n[b\n]c'), '[b\n]a\nc');
      expect(run(down, 'a\n[b\n]c\nd'), 'a\nc\n[b\n]d');
    });

    test('clamps a selection that loses its newline at the bottom', () {
      expect(run(down, '[a\n]b'), 'b\n[a]');
    });

    test('moves past an empty last line', () {
      expect(run(down, 'a|\n'), '\na|');
      expect(run(up, 'a\n|'), '|\na');
    });
  });

  group('deleteLines', () {
    test('removes the caret line and keeps the column below', () {
      expect(run(deleteLines, 'abc\nd|ef\nghi'), 'abc\ng|hi');
    });

    test('stops at the end of a shorter line', () {
      expect(run(deleteLines, 'abcdef|\nxy'), 'xy|');
    });

    test('removes the last line with the break before it', () {
      expect(run(deleteLines, 'abc\nd|e'), 'a|bc');
    });

    test('empties a single-line buffer', () {
      expect(run(deleteLines, 'ab|c'), '|');
      expect(run(deleteLines, '|\n'), '|');
    });

    test('does nothing to an empty buffer', () {
      expect(run(deleteLines, '|'), 'null');
    });

    test('never lands inside a character that takes two code units', () {
      expect(run(deleteLines, 'abc|\nab😀xy'), 'ab|😀xy');
      expect(run(deleteLines, 'ab|c\nab😀xy'), 'ab|😀xy');
      expect(run(deleteLines, 'abcd|\nab😀xy'), 'ab😀|xy');
    });

    test('removes every touched line', () {
      expect(run(deleteLines, 'a\nb[c\nd]e\nf'), 'a\nf|');
      expect(run(deleteLines, 'a\n[b\n]c'), 'a\n|c');
    });
  });

  group('joinLines', () {
    test('joins the caret line with the next and parks at the join', () {
      expect(run(joinLines, 'a|b\n    cd\ne'), 'ab| cd\ne');
    });

    test('does nothing on the last line', () {
      expect(run(joinLines, 'a\nb|'), 'null');
      expect(run(joinLines, '|'), 'null');
    });

    test('adds no space after whitespace or before a blank line', () {
      expect(run(joinLines, 'a |\nb'), 'a |b');
      expect(run(joinLines, 'a\t|\nb'), 'a\t|b');
      expect(run(joinLines, 'a|\n   \nb'), 'a|\nb');
      expect(run(joinLines, '|\n  b'), '|b');
    });

    test('joins every touched line and keeps the selected text', () {
      expect(run(joinLines, 'x[a\n  b\n\t c]d\ny'), 'x[a b c]d\ny');
      expect(run(joinLines, 'x]a\n  b\n\t c[d\ny'), 'x]a b c[d\ny');
    });

    test('skips blank lines inside a selection', () {
      expect(run(joinLines, '[a\n\n  \nb]'), '[a b]');
    });

    test('maps an end inside removed indentation after the separator', () {
      expect(run(joinLines, '[a\n  ]  b'), '[a ]b');
    });

    test('joins a one-line selection with the next line', () {
      expect(run(joinLines, '[ab]\ncd'), '[ab] cd');
    });
  });

  test('rejects offsets outside the buffer', () {
    expect(() => duplicateLines('ab', 0, 3), throwsRangeError);
    expect(() => deleteLines('ab', -1, 0), throwsRangeError);
  });
}

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

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

String selected(String text, int base, int extent) {
  final r = base <= extent
      ? (base: base, extent: extent)
      : (base: extent, extent: base);
  return '${r.base}:${r.extent}:${text.substring(r.base, r.extent)}';
}

void main() {
  group('selectLineRange', () {
    test('selects the caret line', () {
      final r = selectLineRange('one\ntwo\nthree', 5, 5);
      expect(selected('one\ntwo\nthree', r.base, r.extent), '4:7:two');
    });

    test('keeps a backward selection pointing at its anchor', () {
      final r = selectLineRange('one\ntwo\nthree', 7, 4);
      expect(r.base, 7);
      expect(r.extent, 4);
    });

    test('covers every touched line', () {
      final r = selectLineRange('one\ntwo\nthree', 2, 9);
      expect(r.base, 0);
      expect(r.extent, 13);
    });

    test('a selection ending at column 0 skips that line', () {
      final r = selectLineRange('ab\ncd', 0, 3);
      expect(selected('ab\ncd', r.base, r.extent), '0:2:ab');
    });
  });

  group('selectParagraphRange', () {
    test('selects the paragraph at the caret', () {
      const text = 'a\nb\n\nc\nd';
      final r = selectParagraphRange(text, 0, 0);
      expect(selected(text, r.base, r.extent), '0:3:a\nb');
    });

    test('selects the second paragraph', () {
      const text = 'a\nb\n\nc\nd';
      final r = selectParagraphRange(text, 5, 5);
      expect(selected(text, r.base, r.extent), '5:8:c\nd');
    });

    test('a blank line selects itself', () {
      const text = 'a\n\nb';
      final r = selectParagraphRange(text, 2, 2);
      expect(selected(text, r.base, r.extent), '2:2:');
    });
  });

  group('selectEnclosingBracketsRange', () {
    test('selects the pair around the caret', () {
      const text = 'a(b[c]d)e';
      final r = selectEnclosingBracketsRange(text, 4, 4, const []);
      expect(r, isNotNull);
      expect(text.substring(r!.base, r.extent), '[c]');
    });

    test('repeating expands outwards', () {
      const text = 'a(b[c]d)e';
      final inner = selectEnclosingBracketsRange(text, 4, 4, const [])!;
      final outer = selectEnclosingBracketsRange(
        text,
        inner.base,
        inner.extent,
        const [],
      )!;
      expect(text.substring(outer.base, outer.extent), '(b[c]d)');
    });

    test('returns null with no enclosing pair', () {
      expect(selectEnclosingBracketsRange('abc', 1, 1, const []), isNull);
    });
  });

  group('insertLineAbove/Below', () {
    test('above inserts an empty indented line', () {
      expect(run(insertLineAbove, '  a|b'), '  |\n  ab');
    });

    test('below appends after the last line', () {
      expect(run(insertLineBelow, 'a|'), 'a\n|');
    });

    test('below keeps the caret on the new line', () {
      expect(run(insertLineBelow, 'a\nb|'), 'a\nb\n|');
    });

    test('keeps CRLF breaks', () {
      expect(run(insertLineBelow, 'a|\r\nb'), 'a\r\n|\r\nb');
    });
  });

  group('copyLineText', () {
    test('copies the caret line with its break', () {
      expect(copyLineText('a\nb\nc', 2, 2), 'b\n');
    });

    test('the last line copies without a break', () {
      expect(copyLineText('a\nb', 2, 2), 'b');
    });
  });

  group('changeNumber', () {
    test('increments a decimal integer', () {
      expect(run(incrementNumber, 'a|1b'), 'a2|b');
    });

    test('preserves leading zeros', () {
      expect(run(incrementNumber, '|009'), '010|');
    });

    test('decrements across zero', () {
      expect(run(decrementNumber, '|0'), '-1|');
    });

    test('preserves decimal places', () {
      expect(run(incrementNumber, 'x|1.90y'), 'x2.90|y');
    });

    test('preserves hex case and width', () {
      expect(run(incrementNumber, '|0x00ff'), '0x0100|');
    });

    test('returns null with no number', () {
      expect(incrementNumber('abc', 1, 1), isNull);
    });
  });

  group('toggleBlockComments', () {
    test('wraps a selection', () {
      expect(
        run((t, b, e) => toggleBlockComments(t, b, e, '/*', '*/'), '[hi]'),
        '[/* hi */]',
      );
    });

    test('unwraps an included pair', () {
      expect(
        run(
          (t, b, e) => toggleBlockComments(t, b, e, '/*', '*/'),
          '[/* hi */]',
        ),
        '[hi]',
      );
    });

    test('a caret wraps its line', () {
      expect(
        run(
          (t, b, e) => toggleBlockComments(t, b, e, '<!--', '-->'),
          '<a>h|i</a>',
        ),
        '<!-- <a>hi</a> -->|',
      );
    });

    test('does nothing on a blank line', () {
      expect(toggleBlockComments('a\n  \nb', 3, 3, '/*', '*/'), isNull);
    });
  });

  group('pasteWithIndentation', () {
    test('reindents later lines to the caret line', () {
      final edit = pasteWithIndentation('  a', 3, 3, 'x\n  y\n  z');
      expect(edit.text, '  ax\n  y\n  z');
    });

    test('keeps relative steps of the paste', () {
      final edit = pasteWithIndentation('  a', 3, 3, 'x\ny\n  z');
      expect(edit.text, '  ax\n  y\n    z');
    });

    test('emits CRLF for CRLF buffers', () {
      final edit = pasteWithIndentation(
        'a\r\nb',
        1,
        1,
        'x\ny',
        separator: '\r\n',
      );
      expect(edit.text, 'ax\r\ny\r\nb');
    });
  });
}

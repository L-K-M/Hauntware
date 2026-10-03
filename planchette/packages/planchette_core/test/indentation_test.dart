import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Marks the selection in [marked] with `[` and `]` (base first) or a single
/// `|` for a caret, and returns the plain text with both offsets.
(String, int, int) parse(String marked) {
  final caret = marked.indexOf('|');
  if (caret >= 0) {
    return (marked.replaceFirst('|', ''), caret, caret);
  }
  final open = marked.indexOf('[');
  final close = marked.indexOf(']');
  final text = marked.replaceFirst('[', '').replaceFirst(']', '');
  return open < close ? (text, open, close - 1) : (text, open - 1, close);
}

String show(LineEdit edit) {
  final base = edit.selectionBase;
  final extent = edit.selectionExtent;
  if (base == extent) return edit.text.replaceRange(base, base, '|');
  final start = base < extent ? base : extent;
  final end = base < extent ? extent : base;
  return edit.text
      .replaceRange(end, end, base < extent ? ']' : '[')
      .replaceRange(start, start, base < extent ? '[' : ']');
}

String tab(
  String marked, [
  Indentation indentation = const Indentation.spaces(),
]) {
  final (text, base, extent) = parse(marked);
  return show(indentLines(text, base, extent, indentation));
}

String? outdent(
  String marked, [
  Indentation indentation = const Indentation.spaces(),
]) {
  final (text, base, extent) = parse(marked);
  final edit = outdentLines(text, base, extent, indentation);
  return edit == null ? null : show(edit);
}

String enter(
  String marked, {
  Indentation indentation = const Indentation.spaces(),
  bool colon = false,
}) {
  final (text, base, extent) = parse(marked);
  return show(
    insertIndentedNewline(
      text,
      base,
      extent,
      indentation,
      indentAfterColon: colon,
    ),
  );
}

void main() {
  group('detectIndentation', () {
    test('learns the step between nested space-indented lines', () {
      expect(
        detectIndentation('a:\n  b:\n    c: 1\n  d: 2\ne: 3\n'),
        const Indentation.spaces(2),
      );
      expect(
        detectIndentation('def f():\n    if x:\n        return 1\n'),
        const Indentation.spaces(4),
      );
    });

    test('prefers tabs when most indented lines start with one', () {
      expect(
        detectIndentation('all:\n\tcc main.c\n\tstrip a.out\n'),
        const Indentation.tabs(),
      );
    });

    test('ignores block comment continuations and blank lines', () {
      const text =
          '/**\n * Doc.\n */\nclass A {\n    int x;\n\n    int y;\n}\n';
      expect(detectIndentation(text), const Indentation.spaces(4));
    });

    test('reads only the start of very large documents', () {
      final head = 'x\n' * (200 * 1024);
      expect(detectIndentation('$head    a\n        b\n'), isNull);
    });

    test('requires tabs only where the format mandates them', () {
      expect(requiredIndentationFor('/src/Makefile'), const Indentation.tabs());
      expect(
        requiredIndentationFor(r'C:\src\main.go'),
        const Indentation.tabs(),
      );
      expect(requiredIndentationFor('notes.txt'), isNull);
      expect(requiredIndentationFor('Untitled 1'), isNull);
    });

    test('returns null without any indented line', () {
      expect(detectIndentation(''), isNull);
      expect(detectIndentation('one\ntwo\n'), isNull);
    });
  });

  group('indentLines', () {
    test('a caret inserts spaces up to the next tab stop', () {
      expect(tab('|x'), '    |x');
      expect(tab('ab|c'), 'ab  |c');
      expect(tab('\t|x', const Indentation.spaces()), '\t    |x');
    });

    test('a caret inserts a tab in tab-indented documents', () {
      expect(tab('a|b', const Indentation.tabs()), 'a\t|b');
    });

    test('a partial selection within one line is replaced like typing', () {
      expect(tab('a[bc]d'), 'a   |d');
    });

    test('a multi-line selection indents every touched non-blank line', () {
      expect(tab('[one\n\ntwo]\n'), '[    one\n\n    two]\n');
      expect(tab('o[ne\ntw]o'), '    o[ne\n    tw]o');
    });

    test('a selection ending at column 0 leaves that line alone', () {
      expect(tab('[one\ntwo\n]three'), '[    one\n    two\n]three');
    });

    test('a whole single line is indented rather than replaced', () {
      expect(tab('[line]\nnext'), '[    line]\nnext');
    });

    test('backwards selections keep their direction', () {
      expect(tab(']one\ntw[o'), ']    one\n    tw[o');
    });
  });

  group('outdentLines', () {
    test('removes spaces back to the previous tab stop', () {
      expect(outdent('      |x'), '    |x');
      expect(outdent('    x|'), 'x|');
      expect(outdent('  |x'), '|x');
    });

    test('removes one leading tab', () {
      expect(outdent('\t\tx|', const Indentation.tabs()), '\tx|');
    });

    test(
      'outdents every touched line and clamps carets inside indentation',
      () {
        expect(outdent('    [a\n  b\nc]'), '[a\nb\nc]');
        expect(outdent('  |  a'), '|a');
      },
    );

    test('returns null when no line has indentation', () {
      expect(outdent('a|b'), isNull);
    });
  });

  group('insertIndentedNewline', () {
    test('repeats the leading whitespace before the caret', () {
      expect(enter('    foo|'), '    foo\n    |');
      expect(enter('\tfoo|bar'), '\tfoo\n\t|bar');
    });

    test('a caret inside the indentation keeps only what precedes it', () {
      expect(enter('  |  foo'), '  \n  |  foo');
    });

    test('adds a level after an opening bracket', () {
      expect(enter('if (x) {|'), 'if (x) {\n    |');
      expect(enter('  call(|'), '  call(\n      |');
    });

    test('splits a bracket pair onto three lines', () {
      expect(enter('  f() {|}'), '  f() {\n      |\n  }');
      expect(enter('[|  ]'), '[\n    |\n]');
    });

    test('adds a level after a colon only where the language asks', () {
      expect(enter('def f():|', colon: true), 'def f():\n    |');
      expect(enter('Note:|'), 'Note:\n|');
    });

    test('moves whitespace-only indentation to the new line', () {
      expect(enter('    |'), '\n    |');
      expect(enter('a\n    |\nb'), 'a\n\n    |\nb');
    });

    test('replaces a selection', () {
      expect(enter('  a[bc]d'), '  a\n  |d');
    });
  });

  group('deleteIndentBackward', () {
    String? backspace(String marked, [Indentation? indentation]) {
      final (text, caret, _) = parse(marked);
      final edit = deleteIndentBackward(
        text,
        caret,
        indentation ?? const Indentation.spaces(),
      );
      return edit == null ? null : show(edit);
    }

    test('deletes back to the previous tab stop inside indentation', () {
      expect(backspace('        |x'), '    |x');
      expect(backspace('      |x'), '    |x');
    });

    test('leaves ordinary Backspace alone elsewhere', () {
      expect(backspace('a   |'), isNull);
      expect(backspace('     |'), isNull);
      expect(backspace('|x'), isNull);
      expect(backspace('\t|x', const Indentation.tabs()), isNull);
    });
  });

  // Ported from the duplicate indentation PRs (#21, #34) and from review
  // probes; #14 is the implementation that was kept.
  group('ported cases', () {
    test('a caret after a leading tab is still inside the indentation', () {
      expect(tab('\t|'), '\t    |');
    });

    test('a tab before the caret counts as a whole stop of columns', () {
      // The tab puts the caret at column 4 after 'a', so the next stop is 8.
      expect(tab('\ta|b'), '\ta   |b');
    });

    test('rejects an out-of-range selection', () {
      const spaces = Indentation.spaces();
      expect(() => indentLines('abc', 0, 9, spaces), throwsRangeError);
      expect(() => outdentLines('abc', 9, 0, spaces), throwsRangeError);
      expect(
        () => insertIndentedNewline('abc', 0, 9, spaces),
        throwsRangeError,
      );
      expect(() => deleteIndentBackward('abc', 9, spaces), throwsRangeError);
    });

    test('Enter at column 0 does not double the indentation', () {
      expect(enter('|    foo'), '\n|    foo');
    });

    test('Shift+Tab still dedents a file indented the other way', () {
      expect(outdent('\t|x'), '|x');
      expect(outdent('    |x', const Indentation.tabs()), '|x');
    });

    test('outdent keeps a caret inside a later line on that line', () {
      expect(outdent('x\n  |  b'), 'x\n|b');
    });

    test('outdent keeps a backward selection backward', () {
      expect(outdent(']    a\n    b['), ']a\nb[');
    });
  });

  group('review fixes', () {
    test('Tab on a whole CRLF line indents it instead of replacing it', () {
      const spaces = Indentation.spaces(4);
      expect(indentLines('abc\r\ndef', 0, 3, spaces).text, '    abc\r\ndef');
      expect(indentLines('a\r\nb', 0, 4, spaces).text, '    a\r\n    b');
    });

    test('Enter on an indentation-only CRLF line keeps its CR', () {
      final edit = insertIndentedNewline(
        '    \r\nx',
        4,
        4,
        const Indentation.spaces(4),
      );
      expect(edit.text, '\n    \r\nx');
      expect(edit.selectionBase, 5);
    });

    test('an indentation level is at least one column wide', () {
      expect(() => Indentation.spaces(0), throwsA(isA<AssertionError>()));
      expect(() => Indentation.tabs(width: 0), throwsA(isA<AssertionError>()));
    });
  });
}

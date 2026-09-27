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

String show(IndentEdit edit) {
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
  return show(indentSelection(text, base, extent, indentation));
}

String? outdent(
  String marked, [
  Indentation indentation = const Indentation.spaces(),
]) {
  final (text, base, extent) = parse(marked);
  final edit = outdentSelection(text, base, extent, indentation);
  return edit == null ? null : show(edit);
}

String enter(
  String marked, {
  Indentation indentation = const Indentation.spaces(),
  bool colon = false,
}) {
  final (text, base, extent) = parse(marked);
  return show(
    insertNewline(text, base, extent, indentation, indentAfterColon: colon),
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

    test('defaults to tabs only where the format requires them', () {
      expect(defaultIndentationFor('/src/Makefile'), const Indentation.tabs());
      expect(
        defaultIndentationFor(r'C:\src\main.go'),
        const Indentation.tabs(),
      );
      expect(defaultIndentationFor('notes.txt'), const Indentation.spaces());
      expect(defaultIndentationFor('Untitled 1'), const Indentation.spaces());
    });

    test('returns null without any indented line', () {
      expect(detectIndentation(''), isNull);
      expect(detectIndentation('one\ntwo\n'), isNull);
    });
  });

  group('indentSelection', () {
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

  group('outdentSelection', () {
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

  group('insertNewline', () {
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
}

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// A changed run's new buffer with its selection marked: `[` is the base
/// and `]` the extent, or `|` a caret. `a[bc]d` selects `bc` forwards.
String marked(LineEdit edit) {
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

/// A summary of a run's outcome: the marked buffer for a change, or the
/// kind of non-result.
String describe(TextToolOutcome outcome) => switch (outcome) {
  TextToolChanged(:final edit, :final indentation) =>
    '${marked(edit)}${indentation != null ? ' <$indentation>' : ''}',
  TextToolUnchanged(:final indentation) =>
    'unchanged${indentation != null ? ' <$indentation>' : ''}',
  TextToolRefused(:final reason) => 'refused:${reason.name}',
};

/// Runs the catalog tool [id] on a marked buffer (see [marked]) and
/// describes the outcome. Options not listed take their declared defaults;
/// [indentation] and [preference] feed the document context as the
/// controller would.
String run(
  String id,
  String input, {
  Map<String, Object?> options = const {},
  String path = 'test.txt',
  Indentation indentation = const Indentation.spaces(4),
  Indentation? preference,
  String Function(String) fold = _lowercase,
}) {
  final caretMark = input.indexOf('|');
  final int base;
  final int extent;
  final String text;
  if (caretMark >= 0) {
    text = input.replaceFirst('|', '');
    base = extent = caretMark;
  } else {
    final open = input.indexOf('[');
    final close = input.indexOf(']');
    text = input.replaceFirst('[', '').replaceFirst(']', '');
    base = open < close ? open : open - 1;
    extent = close < open ? close : close - 1;
  }
  final tool = textToolById(id)!;
  final resolved = resolveTextToolRange(tool, text, base, extent);
  if (resolved.refusal != null) {
    return describe(TextToolRefused(resolved.refusal!));
  }
  final merged = {
    for (final option in tool.options)
      option.id: options[option.id] ?? option.defaultValue,
  };
  return describe(
    tool.run(
      TextToolRun(
        text: text,
        base: resolved.base,
        extent: resolved.extent,
        caret: resolved.caret,
        ranOn: resolved.ranOn,
        options: merged,
        context: TextToolContext(
          fold: fold,
          indentation: indentation,
          indentationPreference: preference,
          displayPath: path,
        ),
      ),
    ),
  );
}

String _lowercase(String value) => value.toLowerCase();

void main() {
  group('sortLines', () {
    test('sorts the caret document on code points', () {
      // The caret keeps its offset: 'a' moved, the caret did not.
      expect(run('sortLines', 'b\na|\nc'), 'a\nb|\nc');
    });

    test('keeps a caret inside the sorted block', () {
      expect(run('sortLines', 'b|b\na'), 'a|\nbb');
    });

    test('sorts only the touched lines and reselects the result', () {
      expect(run('sortLines', 'x[b\nd\nc]y\nz'), '[cy\nd\nxb]\nz');
      expect(run('sortLines', 'x]b\nd\nc[y\nz'), ']cy\nd\nxb[\nz');
    });

    test('is case-insensitive by default and stable on folded ties', () {
      expect(run('sortLines', 'B\nb\na|'), 'a\nB\nb|');
    });

    test('honours the order and case options', () {
      expect(
        run(
          'sortLines',
          'B\nb\na|',
          options: {'order': 'descending', 'ignoreCase': false},
        ),
        'b\na\nB|',
      );
      // Folded ties keep the original order even descending.
      expect(
        run('sortLines', 'B\nb\na|', options: {'order': 'descending'}),
        'unchanged',
      );
      expect(
        run('sortLines', 'b\nA|', options: {'ignoreCase': false}),
        'A\nb|',
      );
    });

    test('compares digit runs by value when asked', () {
      expect(
        run('sortLines', 'file10\nfile2\nfile1|'),
        'file1\nfile10\nfile2|',
      );
      expect(
        run(
          'sortLines',
          'file10\nfile2\nfile1|',
          options: {'numbersByValue': true},
        ),
        'file1\nfile2\nfile10|',
      );
    });

    test('can lead with line length', () {
      expect(
        run('sortLines', 'ccc\na\nbb|', options: {'byLength': true}),
        'a\nbb\nccc|',
      );
    });

    test('ignores leading whitespace when asked', () {
      expect(
        run('sortLines', '  b\na|', options: {'ignoreLeadingWhitespace': true}),
        'a\n  b|',
      );
      // Equal keys keep the original order — the indent stays.
      expect(
        run(
          'sortLines',
          '  b\n\tb\na|',
          options: {'ignoreLeadingWhitespace': true},
        ),
        'a\n  b\n\tb|',
      );
    });

    test('leaves the first line in place when asked', () {
      expect(
        run('sortLines', 'c\nb\na|', options: {'keepFirstLine': true}),
        'c\na\nb|',
      );
    });

    test('leaves separators in their slots', () {
      expect(run('sortLines', 'b\r\na\r\nc|'), 'a\r\nb\r\nc|');
      expect(run('sortLines', 'b\na|'), 'a\nb|');
    });

    test('reports nothing on a sorted or empty buffer', () {
      expect(run('sortLines', 'a\nb|'), 'unchanged');
      expect(run('sortLines', '|'), 'unchanged');
      expect(run('sortLines', 'a\na|'), 'unchanged');
    });
  });

  group('removeDuplicateLines', () {
    test('drops later copies, keeping the first', () {
      expect(run('removeDuplicateLines', 'a\nb\na|'), 'a\nb|');
      expect(run('removeDuplicateLines', 'a\nb\na\n|'), 'a\nb\n|');
    });

    test('keeps blank lines by default', () {
      expect(run('removeDuplicateLines', 'a\n\n\nb|'), 'unchanged');
      expect(
        run(
          'removeDuplicateLines',
          'a\n\n\nb|',
          options: {'keepBlankLines': false},
        ),
        'a\n\nb|',
      );
    });

    test('keeps CRLF endings', () {
      expect(run('removeDuplicateLines', 'a\r\nb\r\na|'), 'a\r\nb|');
    });

    test('adjacent only collapses runs, not scattered copies', () {
      expect(
        run(
          'removeDuplicateLines',
          'a\na\nb\na|',
          options: {'adjacentOnly': true},
        ),
        'a\nb\na|',
      );
      expect(run('removeDuplicateLines', 'a\na\nb\na|'), 'a\nb|');
    });

    test('compares case-insensitively and whitespace-free when asked', () {
      expect(
        run('removeDuplicateLines', 'A\na|', options: {'ignoreCase': true}),
        'A|',
      );
      expect(
        run(
          'removeDuplicateLines',
          'a\n  a \t|',
          options: {'ignoreSurroundingWhitespace': true},
        ),
        'a|',
      );
    });

    test('removeEveryCopy drops the first copy too', () {
      expect(
        run(
          'removeDuplicateLines',
          'a\nb\na|',
          options: {'removeEveryCopy': true},
        ),
        'b|',
      );
    });

    test('maps a caret through removed lines', () {
      expect(run('removeDuplicateLines', 'a\nb\na|'), 'a\nb|');
      expect(run('removeDuplicateLines', 'a|\nb\na'), 'a|\nb');
    });
  });

  group('removeBlankLines', () {
    test('drops empty and whitespace-only lines', () {
      expect(run('removeBlankLines', 'a\n\nb|'), 'a\nb|');
      expect(run('removeBlankLines', 'a\n  \t\nb|'), 'a\nb|');
    });

    test(
      'a trailing newline ends the file rather than starting a blank line',
      () {
        expect(run('removeBlankLines', 'a\nb\n|'), 'unchanged');
        expect(run('removeBlankLines', 'a\nb\n\n|'), 'a\nb\n|');
      },
    );

    test('leading blank lines come off whole', () {
      expect(run('removeBlankLines', '\n\na|'), 'a|');
    });

    test('an all-blank buffer empties; an empty one was already gone', () {
      expect(run('removeBlankLines', '\n\n|'), '|');
      expect(run('removeBlankLines', '|'), 'unchanged');
    });

    test('touches only the selected lines', () {
      expect(run('removeBlankLines', 'x[a\n\nb]y\n\nz'), 'x[a\nb]y\n\nz');
    });
  });

  group('trimTrailingWhitespace', () {
    test('drops spaces and tabs at each line end', () {
      expect(run('trimTrailingWhitespace', 'a  \nb\t\t\nc|'), 'a\nb\nc|');
    });

    test('keeps CRLF breaks', () {
      expect(run('trimTrailingWhitespace', 'a \r\nb|'), 'a\r\nb|');
    });

    test('a caret inside trailing whitespace lands at the line end', () {
      expect(run('trimTrailingWhitespace', 'a  |\nb'), 'a|\nb');
    });

    test('reports nothing when nothing trails', () {
      expect(run('trimTrailingWhitespace', 'a\nb|'), 'unchanged');
    });
  });

  group('convertIndentationToSpaces', () {
    test('expands leading tabs to columns and adopts the setting', () {
      expect(
        run(
          'convertIndentationToSpaces',
          '\ta\n\t\tb|',
          indentation: const Indentation.tabs(),
        ),
        '    a\n        b| <spaces(4)>',
      );
    });

    test('prefers the host width for a tab-indented file', () {
      expect(
        run(
          'convertIndentationToSpaces',
          '\ta|',
          indentation: const Indentation.tabs(),
          preference: const Indentation.spaces(2),
        ),
        '  a| <spaces(2)>',
      );
    });

    test('keeps a spaces file and still adopts the setting', () {
      expect(
        run('convertIndentationToSpaces', '  a|'),
        'unchanged <spaces(4)>',
      );
    });

    test('refuses where the format requires tabs', () {
      expect(
        run('convertIndentationToSpaces', '\ta|', path: 'Makefile'),
        'refused:requiresTabs',
      );
      expect(
        run('convertIndentationToSpaces', '\ta|', path: '/src/main.go'),
        'refused:requiresTabs',
      );
    });

    test('converts only the selected lines', () {
      expect(
        run(
          'convertIndentationToSpaces',
          '[\ta]\n\tb',
          indentation: const Indentation.tabs(),
        ),
        '[    a]\n\tb <spaces(4)>',
      );
    });
  });

  group('convertIndentationToTabs', () {
    test('converts level-width runs and keeps remainder spaces', () {
      expect(
        run('convertIndentationToTabs', '    a\n  b|'),
        '\ta\n  b| <tabs>',
      );
    });

    test('is a no-op on a tabs file', () {
      expect(
        run(
          'convertIndentationToTabs',
          '\ta|',
          indentation: const Indentation.tabs(),
        ),
        'unchanged <tabs>',
      );
    });
  });

  group('uppercase/lowercase', () {
    test('acts on the word the caret is in, keeping the caret', () {
      expect(run('uppercase', 'he|llo'), 'HE|LLO');
      expect(run('lowercase', 'HE|LLO'), 'he|llo');
    });

    test('the word before the caret wins over the one after', () {
      expect(run('uppercase', 'hi| there'), 'HI| there');
      expect(run('uppercase', 'a |b'), 'a |B');
      expect(run('uppercase', '|hi there'), '|HI there');
    });

    test('refuses where no word touches the caret', () {
      expect(run('uppercase', 'a | b'), 'refused:noWordAtCaret');
      expect(run('uppercase', '|'), 'refused:noWordAtCaret');
    });

    test('acts on a selection and keeps it', () {
      expect(run('uppercase', 'a [b c]d'), 'a [B C]d');
      expect(run('lowercase', 'a ]B C[d'), 'a ]b c[d');
    });

    test('maps accented and astral text without changing length', () {
      expect(run('uppercase', 'héllo| 😀'), 'HÉLLO| 😀');
      // Dart's own mapping keeps ß lowercase-sharp — it does not grow to
      // ẞ, and length never changes either way.
      expect(run('uppercase', 'ß|'), 'unchanged');
    });
  });

  group('straightenQuotes', () {
    test('maps curly singles and doubles to ASCII', () {
      expect(
        run('straightenQuotes', '\u201cfoo\u201d \u2018bar\u2019|'),
        '"foo" \'bar\'|',
      );
    });

    test('covers the low primes too', () {
      expect(
        run('straightenQuotes', '\u201ax\u201b \u201ey\u201f|'),
        '\'x\' "y"|',
      );
    });

    test('touches only a selection when there is one', () {
      expect(
        run('straightenQuotes', '[\u201ca\u201d] \u201cb'),
        '["a"] \u201cb',
      );
    });

    test('reports nothing without curly quotes', () {
      expect(run('straightenQuotes', '"already"|'), 'unchanged');
    });
  });

  group('zapGremlins', () {
    test('deletes C0 controls except the text whitespace', () {
      expect(run('zapGremlins', 'a\x07b\tc\nd\re|'), 'ab\tc\nd\re|');
    });

    test('deletes DEL and C1 controls', () {
      expect(run('zapGremlins', 'a\x7fb\x85c|'), 'abc|');
    });

    test('deletes invisible characters but keeps joiners', () {
      expect(run('zapGremlins', 'a\xadb\u200bc\u2060d\ufeffe|'), 'abcde|');
      expect(run('zapGremlins', 'a\u200cb\u200dc|'), 'unchanged');
    });

    test('deletes bidi controls', () {
      expect(run('zapGremlins', 'a\u202eb\u2066c|'), 'abc|');
    });

    test('damaged characters are opt-in', () {
      expect(run('zapGremlins', 'a\ufffdb|'), 'unchanged');
      expect(
        run('zapGremlins', 'a\ufffdb|', options: {'damaged': true}),
        'ab|',
      );
      expect(
        run('zapGremlins', 'a\ud800b|', options: {'damaged': true}),
        'ab|',
      );
    });

    test('non-ASCII is opt-in and covers gremlins too', () {
      expect(run('zapGremlins', 'héllo|'), 'unchanged');
      expect(
        run('zapGremlins', 'héllo|', options: {'nonAscii': true}),
        'hllo|',
      );
      expect(
        run(
          'zapGremlins',
          'a\x85é|',
          options: {'nonAscii': true, 'controls': false},
        ),
        'a|',
      );
    });

    test('escapes, replaces, or entitizes on request', () {
      expect(
        run('zapGremlins', 'a\x07b|', options: {'action': 'escape'}),
        'a\\u{7}b|',
      );
      expect(
        run(
          'zapGremlins',
          'a\x07b|',
          options: {'action': 'replace', 'character': '!'},
        ),
        'a!b|',
      );
      expect(
        run('zapGremlins', 'a\x07b|', options: {'action': 'entity'}),
        'a&#x7;b|',
      );
    });

    test('leaves astral characters alone unless non-ASCII', () {
      expect(run('zapGremlins', 'a😀b|'), 'unchanged');
      expect(run('zapGremlins', 'a😀b|', options: {'nonAscii': true}), 'ab|');
    });
  });

  group('prefixSuffixLines', () {
    test('inserts a prefix on every line by default', () {
      expect(
        run('prefixSuffixLines', '|b\na', options: {'text': '> '}),
        '|> b\n> a',
      );
    });

    test('inserts a suffix, skipping blank lines by default', () {
      expect(
        run(
          'prefixSuffixLines',
          '|a\n\nb',
          options: {'where': 'suffix', 'text': ';'},
        ),
        '|a;\n\nb;',
      );
      expect(
        run(
          'prefixSuffixLines',
          '|a\n\nb',
          options: {'where': 'suffix', 'text': ';', 'skipBlankLines': false},
        ),
        '|a;\n;\nb;',
      );
    });

    test('remove strips the affix only where it appears', () {
      expect(
        run(
          'prefixSuffixLines',
          '|> a\nb\n> c',
          options: {'mode': 'remove', 'text': '> '},
        ),
        '|a\nb\nc',
      );
      expect(
        run(
          'prefixSuffixLines',
          '|a;\nb\nc;',
          options: {'mode': 'remove', 'where': 'suffix', 'text': ';'},
        ),
        '|a\nb\nc',
      );
    });

    test('an empty affix changes nothing', () {
      expect(run('prefixSuffixLines', '|a\nb'), 'unchanged');
    });
  });

  group('numberLines', () {
    test('adds numbers with the default separator', () {
      expect(run('numberLines', '|b\na'), '|1. b\n2. a');
    });

    test('honours start, step and padding', () {
      expect(
        run(
          'numberLines',
          '|a\nb\nc',
          options: {'start': 8, 'step': 2, 'padding': 'zeros'},
        ),
        '|08. a\n10. b\n12. c',
      );
      expect(
        run('numberLines', '|a\nb\nc', options: {'padding': 'spaces'}),
        '|1. a\n2. b\n3. c',
      );
    });

    test('pads to the widest number', () {
      expect(
        run(
          'numberLines',
          '|a\nb\nc\nd\ne\nf\ng\nh\ni\nj',
          options: {'padding': 'spaces'},
        ),
        '| 1. a\n 2. b\n 3. c\n 4. d\n 5. e'
        '\n 6. f\n 7. g\n 8. h\n 9. i\n10. j',
      );
    });

    test('removes numbers followed by the separator', () {
      expect(
        run('numberLines', '|1. a\n2. b\n3x', options: {'mode': 'remove'}),
        '|a\nb\n3x',
      );
      expect(
        run(
          'numberLines',
          '|  4) a\n2020 report',
          options: {'mode': 'remove', 'separator': ') '},
        ),
        '|a\n2020 report',
      );
    });
  });

  group('joinLinesWith', () {
    test('needs a selection', () {
      expect(run('joinLinesWith', '|a\nb'), 'refused:nothingSelected');
    });

    test('joins the touched lines with the separator', () {
      expect(run('joinLinesWith', '[a\nb\nc]'), '[a, b, c]');
    });

    test('trims and skips blanks by default', () {
      expect(run('joinLinesWith', '[  a \n\n  b]'), '[a, b]');
      expect(
        run(
          'joinLinesWith',
          '[  a \n\n  b]',
          options: {'trim': false, 'skipBlankLines': false},
        ),
        '[  a , ,   b]',
      );
    });

    test('one line is nothing to join', () {
      expect(run('joinLinesWith', '[a]b'), 'unchanged');
    });
  });
}

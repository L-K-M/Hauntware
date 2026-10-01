import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

// Slice 8: Unicode/ASCII and JSON tools. The marked-buffer harness mirrors
// text_tools_test.dart: `[` is the selection base, `]` the extent, `|` a
// caret. A backward selection writes `]` before `[`.

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

String describe(TextToolOutcome outcome) => switch (outcome) {
  TextToolChanged(:final edit) => marked(edit),
  TextToolUnchanged() => 'unchanged',
  TextToolRefused(:final reason) => 'refused:${reason.name}',
};

TextToolOutcome outcomeOf(String id, String input) {
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
    return TextToolRefused(resolved.refusal!);
  }
  return tool.run(
    TextToolRun(
      text: text,
      base: resolved.base,
      extent: resolved.extent,
      caret: resolved.caret,
      ranOn: resolved.ranOn,
      options: {for (final o in tool.options) o.id: o.defaultValue},
      context: TextToolContext(
        fold: (s) => s.toLowerCase(),
        indentation: const Indentation.spaces(4),
      ),
    ),
  );
}

String run(String id, String input) => describe(outcomeOf(id, input));

void main() {
  group('slice 8 catalog', () {
    test('the six tools exist, default to document scope, take no options', () {
      for (final id in [
        'composeAccents',
        'decomposeAccents',
        'stripDiacritics',
        'convertToAscii',
        'formatJson',
        'minifyJson',
      ]) {
        final tool = textToolById(id);
        expect(tool, isNotNull, reason: id);
        expect(tool!.scope, TextToolScope.document, reason: id);
        expect(tool.options, isEmpty, reason: id);
      }
    });
  });

  group('composeAccents', () {
    test('composes a base letter plus mark to NFC', () {
      expect(run('composeAccents', 'e\u0301|'), '\u00e9|');
    });

    test('an already composed buffer is unchanged', () {
      expect(run('composeAccents', '\u00e9|'), 'unchanged');
    });

    test('plain ASCII is unchanged', () {
      expect(run('composeAccents', 'abc|'), 'unchanged');
    });

    test('emoji and non-Latin pass through', () {
      expect(run('composeAccents', '\u{1f600}|'), 'unchanged');
      expect(run('composeAccents', '\u65e5\u672c|'), 'unchanged');
    });

    test('a surrogate pair is not split by the caret map', () {
      expect(run('composeAccents', '\u{1f600}a\u030a|'), isNot('unchanged'));
    });

    test('a selection composes only its slice', () {
      expect(run('composeAccents', '[e\u0301] \u00e9'), '[\u00e9] \u00e9');
    });

    test('a backward selection keeps its direction', () {
      expect(run('composeAccents', ']e\u0301[e'), ']\u00e9[e');
    });
  });

  group('decomposeAccents', () {
    test('decomposes to NFD', () {
      expect(run('decomposeAccents', '\u00e9|'), 'e\u0301|');
    });

    test('an already decomposed buffer is unchanged', () {
      expect(run('decomposeAccents', 'e\u0301|'), 'unchanged');
    });

    test('emoji and non-Latin pass through', () {
      expect(run('decomposeAccents', '\u{1f600}|'), 'unchanged');
      expect(run('decomposeAccents', '\u65e5\u672c|'), 'unchanged');
    });

    test('a selection decomposes only its slice', () {
      expect(run('decomposeAccents', '[\u00e9] \u00e9'), '[e\u0301] \u00e9');
    });

    test('a backward selection keeps its direction', () {
      expect(run('decomposeAccents', ']\u00e9[e'), ']e\u0301[e');
    });
  });

  group('stripDiacritics', () {
    test('removes combining marks, leaving base letters', () {
      expect(run('stripDiacritics', '\u00e9|'), 'e|');
      expect(run('stripDiacritics', 'e\u0301|'), 'e|');
    });

    test('plain ASCII is unchanged', () {
      expect(run('stripDiacritics', 'abc|'), 'unchanged');
    });

    test('characters without a decomposition pass through', () {
      // ø has no canonical decomposition, so stripping leaves it.
      expect(run('stripDiacritics', '\u00f8|'), 'unchanged');
    });

    test('emoji, ZWJ sequences and non-Latin pass through', () {
      expect(run('stripDiacritics', '\u{1f600}|'), 'unchanged');
      // Family emoji needs its zero-width joiners; they are not marks.
      expect(
        run('stripDiacritics', '\u{1f468}\u200d\u{1f469}\u200d\u{1f467}|'),
        'unchanged',
      );
      expect(run('stripDiacritics', '\u65e5\u672c|'), 'unchanged');
    });

    test('a selection strips only its slice', () {
      expect(run('stripDiacritics', '[\u00e9] \u00e9'), '[e] \u00e9');
    });
  });

  group('convertToAscii', () {
    test('converts quotes, dashes and ellipsis', () {
      expect(run('convertToAscii', '\u2018hi\u2019|'), "'hi'|");
      expect(run('convertToAscii', 'a\u2013b\u2014c|'), 'a-b-c|');
      expect(run('convertToAscii', 'wait\u2026|'), 'wait...|');
    });

    test('converts ligatures and accented Latin', () {
      expect(run('convertToAscii', '\u00e6|'), 'ae|');
      expect(run('convertToAscii', '\u00df|'), 'ss|');
      expect(run('convertToAscii', '\ufb01|'), 'fi|');
      expect(run('convertToAscii', 'caf\u00e9|'), 'cafe|');
      expect(run('convertToAscii', '\u00f8|'), 'o|');
    });

    test('pure ASCII is unchanged without a detail', () {
      final outcome = outcomeOf('convertToAscii', 'abc|');
      expect(outcome, isA<TextToolUnchanged>());
      expect((outcome as TextToolUnchanged).detail, isNull);
    });

    test('unmapped non-ASCII is kept literal and reported', () {
      final outcome = outcomeOf('convertToAscii', 'caf\u00e9 \u65e5\u672c|');
      expect(outcome, isA<TextToolChanged>());
      final changed = outcome as TextToolChanged;
      expect(changed.edit.text, 'cafe \u65e5\u672c');
      expect(changed.detail, 'unmapped:2');
    });

    test('emoji and Cyrillic are kept, never deleted', () {
      final outcome = outcomeOf('convertToAscii', '\u{1f600}\u0414|');
      expect(outcome, isA<TextToolUnchanged>());
      final unchanged = outcome as TextToolUnchanged;
      expect(unchanged.detail, 'unmapped:2');
    });

    test('a lone unmapped buffer reports rather than empties', () {
      expect(run('convertToAscii', '[\u65e5\u672c]'), 'unchanged');
      final outcome = outcomeOf('convertToAscii', '[\u65e5\u672c]');
      expect((outcome as TextToolUnchanged).detail, 'unmapped:2');
    });

    test('a selection converts only its slice', () {
      expect(run('convertToAscii', '[\u00e9] \u00e9'), '[e] \u00e9');
    });

    test('a backward selection keeps its direction', () {
      expect(run('convertToAscii', ']\u00e9[e'), ']e[e');
    });
  });

  group('formatJson', () {
    test('pretty-prints with two-space indent', () {
      expect(
        run('formatJson', '{"b":2,"a":[1,2]}|'),
        '{\n  "b": 2,\n  "a": [\n    1,\n    2\n  ]\n}|',
      );
    });

    test('an already formatted buffer is unchanged', () {
      expect(run('formatJson', '{\n  "a": 1\n}|'), 'unchanged');
    });

    test('empty containers stay compact', () {
      expect(
        run('formatJson', '{"a":{},"b":[]}|'),
        '{\n  "a": {},\n  "b": []\n}|',
      );
    });

    test('large integers and exponents keep their spelling', () {
      expect(
        run('formatJson', '{"n":9007199254740993,"e":1e1000}|'),
        '{\n  "n": 9007199254740993,\n  "e": 1e1000\n}|',
      );
      expect(
        run('formatJson', '[1.000,1E+02,-0.0]|'),
        '[\n  1.000,\n  1E+02,\n  -0.0\n]|',
      );
    });

    test('escaped strings keep their escapes verbatim', () {
      expect(
        run('formatJson', r'{"s":"A"}|'.replaceAll('A', r'\u0041')),
        '{\n  "s": "\\u0041"\n}|',
      );
    });

    test('object order is preserved', () {
      expect(run('formatJson', '{"z":1,"a":2}|'), '{\n  "z": 1,\n  "a": 2\n}|');
    });

    test('nesting formats at every level', () {
      final outcome = outcomeOf('formatJson', '{"a":{"b":[1,{"c":null}]}}|');
      expect(outcome, isA<TextToolChanged>());
      final text = (outcome as TextToolChanged).edit.text;
      expect(text, contains('"b": ['));
      expect(text, contains('"c": null'));
    });

    test('a document caret formats the whole buffer', () {
      expect(run('formatJson', '[{"a":1}]|'), '[\n  {\n    "a": 1\n  }\n]|');
    });

    test('a selected value formats in place', () {
      expect(run('formatJson', 'x[{"a":1}]y'), 'x[{\n  "a": 1\n}]y');
    });

    test('a backward selection keeps its direction', () {
      expect(run('formatJson', 'x][{"a":1}][y'), isNot('unchanged'));
      final outcome = outcomeOf('formatJson', 'x]{"a":1}[y');
      expect(outcome, isA<TextToolChanged>());
      final edit = (outcome as TextToolChanged).edit;
      expect(edit.selectionBase, greaterThan(edit.selectionExtent));
    });

    test('invalid JSON refuses with line and column', () {
      for (final bad in [
        '',
        '{',
        '{"a":1,}',
        "{'a':1}",
        '{"a":1} trailing',
        '{"a":01}',
        '{"a":tru}',
        '{"a":"\\x"}',
        '{"a":"\n"}',
      ]) {
        final outcome = outcomeOf('formatJson', '$bad|');
        expect(outcome, isA<TextToolRefused>(), reason: bad);
        final refused = outcome as TextToolRefused;
        expect(refused.reason, TextToolRefusal.invalidJson, reason: bad);
        expect(refused.detail, contains('line '), reason: bad);
        expect(refused.detail, contains('column '), reason: bad);
      }
    });

    test('a second-line error reports line 2', () {
      final outcome = outcomeOf('formatJson', '{\n"a":01}|');
      final refused = outcome as TextToolRefused;
      expect(refused.detail, contains('line 2'));
    });
  });

  group('minifyJson', () {
    test('removes insignificant whitespace', () {
      expect(run('minifyJson', '{\n  "a": [1, 2]\n}|'), '{"a":[1,2]}|');
    });

    test('an already minified buffer is unchanged', () {
      expect(run('minifyJson', '{"a":[1,2]}|'), 'unchanged');
    });

    test('large integers, exponents and escapes keep their spelling', () {
      expect(
        run('minifyJson', '{ "n" : 9007199254740993 }|'),
        '{"n":9007199254740993}|',
      );
      expect(run('minifyJson', '[ 1e1000 , 1E+02 ]|'), '[1e1000,1E+02]|');
      expect(run('minifyJson', '{ "s" : "\\u0041" }|'), '{"s":"\\u0041"}|');
    });

    test('invalid JSON refuses with line and column', () {
      final outcome = outcomeOf('minifyJson', '{"a":}|');
      final refused = outcome as TextToolRefused;
      expect(refused.reason, TextToolRefusal.invalidJson);
      expect(refused.detail, contains('line 1'));
      expect(refused.detail, contains('column '));
    });

    test('a selected value minifies in place', () {
      expect(run('minifyJson', 'x[{ "a" : 1 }]y'), 'x[{"a":1}]y');
    });

    test('a backward selection keeps its direction', () {
      final outcome = outcomeOf('minifyJson', 'x]{ "a" : 1 }[y');
      expect(outcome, isA<TextToolChanged>());
      final edit = (outcome as TextToolChanged).edit;
      expect(edit.selectionBase, greaterThan(edit.selectionExtent));
    });
  });
}

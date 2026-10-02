import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

String wrap(
  String text, {
  int width = 10,
  ParagraphWrapMode mode = ParagraphWrapMode.fill,
  List<String> markers = const [],
}) => hardWrapText(
  text,
  width: width,
  tabWidth: 4,
  lineEnding: LineEnding.lf,
  mode: mode,
  commentMarkers: markers,
);

TextToolOutcome runTool(
  String id,
  String text, {
  int base = 0,
  int extent = 0,
  Map<String, Object?> options = const {},
  String path = 'notes.txt',
}) {
  final tool = textToolById(id)!;
  final range = resolveTextToolRange(tool, text, base, extent);
  return tool.run(
    TextToolRun(
      text: text,
      base: range.base,
      extent: range.extent,
      caret: range.caret,
      ranOn: range.ranOn,
      options: {
        for (final option in tool.options) option.id: option.defaultValue,
        ...options,
      },
      context: TextToolContext(
        fold: (s) => s.toLowerCase(),
        indentation: const Indentation.spaces(),
        displayPath: path,
      ),
    ),
  );
}

void main() {
  test('fills paragraphs and preserves blank lines and final breaks', () {
    expect(
      wrap('one two\nthree four\n\nfive six\n'),
      'one two\nthree four\n\nfive six\n',
    );
    expect(wrap('one\ntwo three'), 'one two\nthree');
    expect(
      wrap('one\ntwo three', mode: ParagraphWrapMode.lines),
      'one\ntwo three',
    );
  });
  test('quote and comment prefixes repeat within the width', () {
    expect(wrap('> one two three four'), '> one two\n> three\n> four');
    expect(
      wrap('  // one two\n  // three', markers: ['//']),
      '  // one\n  // two\n  // three',
    );
    expect(wrap('>\tone two three four'), '>\tone\n>\ttwo\n>\tthree\n>\tfour');
  });
  test('width counts wide characters and intact Unicode clusters', () {
    expect(wrap('中 文 字', width: 5), '中 文\n字');
    expect(
      wrap('👩‍👩‍👧‍👦 e\u0301 xyz', width: 4),
      '👩‍👩‍👧‍👦 e\u0301\nxyz',
    );
    expect(wrap('abcdefgh xyz', width: 4), 'abcdefgh\nxyz');
  });
  test('leaves list structure and its original separators alone', () {
    const list = '- first long item\r\n  continuation\r\n- second item';
    expect(wrap(list, width: 4), list);
  });
  test('preserves blank-line whitespace and mixed separator slots', () {
    expect(
      wrap('one two three\r\n \t\r\nshort'),
      'one two\nthree\r\n \t\r\nshort',
    );
  });
  test(
    'catalog tab conversion measures Unicode and preserves CRLF/direction',
    () {
      const source = '中\ta\tb\r\n👩‍👩‍👧‍👦\tc';
      const expected = '中  a   b\r\n👩‍👩‍👧‍👦  c';
      final outcome =
          runTool('convertTabsToSpaces', source, base: source.length, extent: 0)
              as TextToolChanged;
      expect(outcome.edit.text, expected);
      expect(outcome.changed, 3);
      expect(outcome.edit.selectionBase, expected.length);
      expect(outcome.edit.selectionExtent, 0);
    },
  );
  test('tab conversion excludes a line touched only at column zero', () {
    final result =
        runTool('convertTabsToSpaces', 'a\tb\nc\td', base: 0, extent: 4)
            as TextToolChanged;
    expect(result.edit.text, 'a   b\nc\td');
    expect(result.edit.selectionExtent, 6);
  });
  test('tab conversion refuses formats requiring leading tabs', () {
    for (final path in ['Makefile', 'x.go']) {
      final result =
          runTool('convertTabsToSpaces', '\tx\ty', path: path)
              as TextToolRefused;
      expect(result.reason, TextToolRefusal.requiresTabs);
    }
  });
  test('catalog hard wrap only rewrites the paragraph at the caret', () {
    const source = 'untouched text\n\none two three four\n\nlast';
    final caret = source.indexOf('one') + 1;
    final result =
        runTool(
              'hardWrap',
              source,
              base: caret,
              extent: caret,
              options: {'width': 10},
            )
            as TextToolChanged;
    expect(result.edit.text, 'untouched text\n\none two\nthree four\n\nlast');
    expect(result.edit.selectionBase, caret);
    expect(result.edit.selectionExtent, caret);
  });
  test(
    'selected hard wrap preserves direction and repeats language comments',
    () {
      const source = '// one two\n// three four';
      const expected = '// one two\n// three\n// four';
      final result =
          runTool(
                'hardWrap',
                source,
                base: source.length,
                extent: 0,
                options: {'width': 10},
                path: 'x.dart',
              )
              as TextToolChanged;
      expect(result.edit.text, expected);
      expect(result.edit.selectionBase, expected.length);
      expect(result.edit.selectionExtent, 0);
    },
  );
  test('already wrapped text and text without tabs report no change', () {
    expect(runTool('hardWrap', 'short'), isA<TextToolUnchanged>());
    expect(runTool('convertTabsToSpaces', 'short'), isA<TextToolUnchanged>());
  });
  test('tab expansion refuses oversized output before allocating a stop', () {
    final result = runTool(
      'convertTabsToSpaces',
      '\t',
      options: {'width': textDocumentMaximumBytes + 1},
    );
    expect(result, isA<TextToolRefused>());
  });
  test(
    'hard wrap bounds repeated prefixes before building oversized output',
    () {
      final source = ' ' * 8192 + List.filled(1100, 'x').join(' ');
      expect(
        runTool('hardWrap', source, options: {'width': 5}),
        isA<TextToolRefused>(),
      );
    },
  );
}

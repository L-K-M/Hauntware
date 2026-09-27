import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  group('leadingWhitespace', () {
    test('is the run of blanks that opens the caret line', () {
      expect(leadingWhitespace('one two', 0), '');
      expect(leadingWhitespace('  one two', 0), '  ');
      expect(leadingWhitespace('\t one', 0), '\t ');
      expect(leadingWhitespace('  one two', 6), '  ');
    });

    test('stops at the first non-blank and never crosses a line', () {
      expect(leadingWhitespace('  \n  x', 0), '  ');
      expect(leadingWhitespace('  \n  x', 4), '  ');
      expect(leadingWhitespace('a  b', 4), '');
      expect(leadingWhitespace('a \t b', 4), '');
    });

    test('tolerates an offset outside the text', () {
      expect(leadingWhitespace('  x', 99), '  ');
      expect(leadingWhitespace('', 0), '');
    });
  });

  group('indentForNewLine', () {
    test('carries the current line indentation', () {
      expect(indentForNewLine('    x', 5, unit: '  '), '    ');
      expect(indentForNewLine('  a\n  b', 6, unit: '  '), '  ');
    });

    test('adds a level after an opening bracket', () {
      expect(indentForNewLine('  {', 3, unit: '  '), '    ');
      expect(indentForNewLine('a[', 2, unit: '\t'), '\t');
      expect(indentForNewLine('foo(', 4, unit: '  '), '  ');
    });

    test('does not add a level after a closing bracket', () {
      expect(indentForNewLine('  }', 3, unit: '  '), '  ');
      expect(indentForNewLine('  ]', 3, unit: '  '), '  ');
      expect(indentForNewLine('  )', 3, unit: '  '), '  ');
    });

    test('adds a level after a colon only when the language wants it', () {
      // YAML and the INI family are line-oriented, so a trailing colon opens a
      // block. In a language where a colon is punctuation it does not.
      expect(indentForNewLine('key:', 4, unit: '  ', afterColon: true), '  ');
      expect(indentForNewLine('key:', 4, unit: '  ', afterColon: false), '');
      // The caret before the value still sees the key's colon, so it indents.
      expect(indentForNewLine('  a: b', 5, unit: '  ', afterColon: true), '    ');
      // Past the value there is no trailing opener, so it does not.
      expect(indentForNewLine('  a: b', 6, unit: '  ', afterColon: true), '  ');
    });

    test('a blank line does not gain a level', () {
      expect(indentForNewLine('   ', 3, unit: '  '), '   ');
      expect(indentForNewLine('', 0, unit: '  '), '');
    });

    test('trailing whitespace after a bracket is still a bracket', () {
      expect(indentForNewLine('  {   ', 6, unit: '  '), '    ');
    });

    test('an empty unit adds nothing', () {
      expect(indentForNewLine('  {', 3, unit: ''), '  ');
    });

    test('a caret in the middle of the line uses that line', () {
      expect(indentForNewLine('  a  b', 5, unit: '  '), '  ');
    });
  });

  group('indentRange', () {
    test('covers the leading whitespace before the caret', () {
      expect(indentRange('  one', 4), (start: 0, end: 2));
      expect(indentRange('  one', 2), (start: 0, end: 2));
      expect(indentRange('one', 3), (start: 0, end: 0));
    });

    test('is measured from the line start, not the text start', () {
      expect(indentRange('a\n    b', 7), (start: 2, end: 6));
      expect(indentRange('a\n  b', 4), (start: 2, end: 4));
    });

    test('a caret at column zero still covers the line it is on', () {
      // Tab replaces the line's whole indent, so the range does not depend on
      // where in that indent the caret happens to be.
      expect(indentRange('  one', 0), (start: 0, end: 2));
      expect(indentRange('one', 0), (start: 0, end: 0));
    });
  });
}

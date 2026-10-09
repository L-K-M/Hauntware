import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  test('keycap emoji are wide, unrelated enclosing marks stay narrow', () {
    expect(textColumnAfter('1\ufe0f\u20e3'), 2);
    expect(textColumnAfter('#\ufe0f\u20e3'), 2);
    expect(textColumnAfter('*\u20e3'), 2);
    expect(textColumnAfter('1'), 1);
    expect(textColumnAfter('#'), 1);
    expect(textColumnAfter('a\u20e3'), 1);
  });
  test('tabs advance to the next stop, not a fixed number of spaces', () {
    expect(textColumnAfter('\tind', tabWidth: 8), 11);
    expect(textColumnAfter('a\tb\t', tabWidth: 4), 8);
    expect(textColumnAfter('abcd\t', tabWidth: 4), 8);
  });
  test('combining sequences, CJK and emoji use text-cell columns', () {
    expect(textColumnAfter('e\u0301'), 1);
    expect(textColumnAfter('\u0301'), 0);
    expect(textColumnAfter('中文'), 4);
    expect(textColumnAfter('👩‍👩‍👧‍👦'), 2);
    expect(textColumnAfter('🇨🇭'), 2);
    expect(textColumnAfter('©'), 1);
    expect(textColumnAfter('©️'), 2);
    expect(textColumnAfter('a\ufe0f'), 1);
  });
  test('line breaks reset columns, and invalid stops are rejected', () {
    expect(textColumnAfter('abc\r\nx\t', tabWidth: 4), 4);
    expect(() => textColumnAfter('x', tabWidth: 0), throwsArgumentError);
    expect(() => textColumnAfter('x', initialColumn: -1), throwsArgumentError);
  });
}

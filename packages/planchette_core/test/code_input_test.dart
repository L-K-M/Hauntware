import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  group('opensPair', () {
    test('an opener pairs at the caret', () {
      expect(opensPair(SyntaxLanguages.dart, '(', 'f(', 2), isTrue);
      expect(opensPair(SyntaxLanguages.dart, '{', 'f(', 2), isTrue);
      expect(opensPair(SyntaxLanguages.dart, '"', 'f(', 2), isTrue);
    });

    test('a non-opener never pairs', () {
      expect(opensPair(SyntaxLanguages.dart, ')', 'f(', 2), isFalse);
      expect(opensPair(SyntaxLanguages.dart, 'x', 'f(', 2), isFalse);
    });

    test('the same character already under the caret disqualifies', () {
      // Typing ( in '(|x' leaves '((x', but typing ( in '(|(' is a
      // second open, not a pair — the closer step is movesOverCloser's.
      expect(opensPair(SyntaxLanguages.dart, '(', 'x(', 1), isFalse);
    });

    test('prose does not pair', () {
      expect(opensPair(SyntaxLanguages.markdown, '(', 'a', 1), isFalse);
      expect(opensPair(null, '(', 'a', 1), isFalse);
    });

    test('a quote after a word character is an apostrophe, not a pair', () {
      // `don'` grows a contraction, not `don''` — the closer would strand.
      expect(opensPair(SyntaxLanguages.yaml, "'", 'don', 3), isFalse);
      expect(opensPair(SyntaxLanguages.dart, '"', 'say', 3), isFalse);
      expect(opensPair(SyntaxLanguages.yaml, "'", 'f9', 2), isFalse);
      // After a bracket, whitespace or nothing, a quote still opens a pair.
      expect(opensPair(SyntaxLanguages.dart, "'", 'f(', 2), isTrue);
      expect(opensPair(SyntaxLanguages.yaml, "'", 'key: ', 5), isTrue);
      expect(opensPair(SyntaxLanguages.dart, "'", '', 0), isTrue);
      // Brackets are calls, not apostrophes — they pair after word chars.
      expect(opensPair(SyntaxLanguages.dart, '(', 'foo', 3), isTrue);
    });
  });

  group('movesOverCloser', () {
    test('a closer steps over its pair', () {
      expect(movesOverCloser(SyntaxLanguages.dart, ')', '()', 1), isTrue);
      expect(movesOverCloser(SyntaxLanguages.dart, '"', '""', 1), isTrue);
      expect(movesOverCloser(SyntaxLanguages.dart, "'", "''", 1), isTrue);
    });

    test('a mismatched closer is a real character', () {
      expect(movesOverCloser(SyntaxLanguages.dart, ')', 'x)', 1), isFalse);
      expect(movesOverCloser(SyntaxLanguages.dart, ']', '(]', 1), isFalse);
      expect(movesOverCloser(SyntaxLanguages.dart, ')', '(x', 1), isFalse);
    });

    test('the buffer edge is safe', () {
      expect(movesOverCloser(SyntaxLanguages.dart, ')', '', 0), isFalse);
      // Offset 0 cannot hold a bracket's opener, so a closer typed before a
      // bracket at the start of the buffer is a real character, not a skip.
      expect(movesOverCloser(SyntaxLanguages.dart, ')', ')', 0), isFalse);
      expect(movesOverCloser(SyntaxLanguages.dart, ']', ']', 0), isFalse);
      expect(movesOverCloser(SyntaxLanguages.dart, '}', '}', 0), isFalse);
      // A quote is its own opener: stepping over it at the edge stays right.
      expect(movesOverCloser(SyntaxLanguages.dart, '"', '"', 0), isTrue);
      expect(movesOverCloser(SyntaxLanguages.dart, "'", "'", 0), isTrue);
    });

    test('a quote steps over the quote already under the caret', () {
      // Typing " in 'log|"x"' closes 'log"' rather than stranding a second
      // quote; only the character under the caret carries that evidence.
      expect(movesOverCloser(SyntaxLanguages.dart, '"', '"hello"', 6), isTrue);
      expect(movesOverCloser(SyntaxLanguages.dart, "'", "it's'", 4), isTrue);
      // A different quote under the caret is still a real character.
      expect(movesOverCloser(SyntaxLanguages.dart, '"', "'", 0), isFalse);
      expect(movesOverCloser(SyntaxLanguages.dart, "'", '"', 0), isFalse);
    });

    test('prose never steps', () {
      expect(movesOverCloser(SyntaxLanguages.markdown, ')', '()', 1), isFalse);
      expect(movesOverCloser(null, ')', '()', 1), isFalse);
    });
  });

  test('closerFor completes openers only', () {
    expect(closerFor('('), ')');
    expect(closerFor('`'), '`');
    expect(closerFor('x'), isNull);
    expect(closerFor(')'), isNull);
  });
}

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
      expect(movesOverCloser(SyntaxLanguages.dart, ')', ')', 0), isTrue);
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

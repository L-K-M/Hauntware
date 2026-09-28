import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

/// Splits `|` out of [marked] as the caret.
(String, int) _caret(String marked) {
  final caret = marked.indexOf('|');
  return (marked.replaceFirst('|', ''), caret);
}

/// The caret after one jump from the `|` in [marked], drawn back in.
String? _jump(String marked, {String path = 'a.js'}) {
  final (text, caret) = _caret(marked);
  final jump = bracketJump(text, caret, _tokens(text, path));
  if (jump == null) return null;
  return text.replaceRange(jump.offset, jump.offset, '|');
}

List<SyntaxToken> _tokens(String text, String path) {
  final language = syntaxLanguageFor(path);
  return language == null ? const [] : tokenizeSyntax(text, language);
}

void main() {
  group('matchBracket', () {
    test('pairs each bracket type in both directions', () {
      const text = 'f(a[1]) { b }';
      expect(matchBracket(text, 2, const []), const BracketMatch(1, 6));
      expect(matchBracket(text, 7, const []), const BracketMatch(6, 1));
      expect(matchBracket(text, 3, const []), const BracketMatch(3, 5));
      expect(matchBracket(text, 9, const []), const BracketMatch(8, 12));
    });

    test('prefers the bracket before the caret, then the one after', () {
      // Between `)` and `(`: the closer just typed wins.
      expect(matchBracket('(a)(b)', 3, const []), const BracketMatch(2, 0));
      // A bracket before the caret without a partner yields to the next.
      expect(matchBracket(')(b)', 1, const []), const BracketMatch(1, 3));
    });

    test('a preferred bracket beside the caret wins', () {
      expect(
        matchBracket('(a)(b)', 3, const [], preferred: 3),
        const BracketMatch(3, 5),
      );
      // One that no longer touches the caret is ignored.
      expect(
        matchBracket('(a)(b)', 3, const [], preferred: 5),
        const BracketMatch(2, 0),
      );
    });

    test('counts depth per bracket type', () {
      expect(matchBracket('((a))', 0, const []), const BracketMatch(0, 4));
      expect(matchBracket('([)]', 0, const []), const BracketMatch(0, 2));
      expect(matchBracket('([)]', 1, const []), const BracketMatch(0, 2));
    });

    test('code skips brackets in strings and comments', () {
      const text = 'f(")", /* ( */ x)';
      final tokens = _tokens(text, 'a.js');
      expect(matchBracket(text, 1, tokens), const BracketMatch(1, 16));
      expect(matchBracket(text, 17, tokens), const BracketMatch(16, 1));
    });

    test('a bracket inside a string or comment pairs within it', () {
      const text = 'x = "(a)" + ")"; // (see f)';
      final tokens = _tokens(text, 'a.js');
      expect(matchBracket(text, 6, tokens), const BracketMatch(5, 7));
      expect(matchBracket(text, 20, tokens), const BracketMatch(20, 26));
      // The lone `)` in the second string has no partner in that string.
      expect(matchBracket(text, 14, tokens), isNull);
    });

    test('other tokens hold real brackets', () {
      const text = r'echo ${HOME}';
      final tokens = _tokens(text, 'a.sh');
      expect(tokens.any((t) => t.type == SyntaxTokenType.meta), isTrue);
      expect(matchBracket(text, 7, tokens), const BracketMatch(6, 11));
    });

    test('is null without a partner or a bracket', () {
      expect(matchBracket('(a', 1, const []), isNull);
      expect(matchBracket('a)', 2, const []), isNull);
      expect(matchBracket('abc', 1, const []), isNull);
      expect(matchBracket('', 0, const []), isNull);
    });
  });

  group('bracketJump', () {
    test('keeps the side of the bracket the caret was on', () {
      expect(_jump('if (x) {|\n  y;\n}'), 'if (x) {\n  y;\n}|');
      expect(_jump('if (x) {\n  y;\n}|'), 'if (x) {|\n  y;\n}');
      expect(_jump('f|(a, b)'), 'f(a, b|)');
      expect(_jump('f(a, b|)'), 'f|(a, b)');
    });

    test('a second jump returns, even between adjacent brackets', () {
      const text = '((a))';
      final first = bracketJump(text, 0, const [])!;
      expect(first, const BracketJump(4, 4));
      // Without the hint, the `)` before offset 4 would win.
      expect(bracketJump(text, 4, const []), const BracketJump(2, 1));
      final second = bracketJump(text, 4, const [], preferred: first.bracket);
      expect(second, const BracketJump(0, 0));
    });

    test('goes to the closer of the innermost pair around the caret', () {
      expect(_jump('f(a, b|, c)'), 'f(a, b, c|)');
      expect(_jump('{ [1, 2], x| }'), '{ [1, 2], x |}');
      // An unclosed opener does not hide the pair around it.
      expect(_jump('{ (a| }'), '{ (a |}');
    });

    test('skips strings and comments when looking outwards', () {
      expect(_jump('f(x /* ( */|)'), 'f|(x /* ( */)');
      // Inside a string, its own pairs come first, then the code around it.
      expect(_jump('f(a, "(|b)")'), 'f(a, "(b)|")');
      expect(_jump('f(a, "(b|", c)'), 'f(a, "(b", c|)');
    });

    test('stays linear past a run of unclosed brackets', () {
      // Each unclosed `(` would otherwise scan to the end for its partner.
      // Quadratic, this takes about 25 seconds; linear, milliseconds.
      final text = '{${'(' * 100000} x }';
      final clock = Stopwatch()..start();
      expect(
        bracketJump(text, text.length - 2, const []),
        BracketJump(text.length - 1, text.length - 1),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('is null when there is nowhere to go', () {
      expect(_jump('plain| text'), isNull);
      expect(_jump('|'), isNull);
      expect(_jump('(a|'), isNull);
    });
  });

  test('a caret outside the text is rejected at the entry points', () {
    expect(() => matchBracket('ab', 5, const []), throwsRangeError);
    expect(() => bracketJump('ab', 5, const []), throwsRangeError);
    expect(() => bracketJump('ab', -1, const []), throwsRangeError);
  });
}

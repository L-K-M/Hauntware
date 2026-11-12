import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

// The search wrapper and span builder live here, in Flutter ranges and
// TextSpans; the pure-Dart tokenizer and search algorithm are tested in
// planchette_core. The Séance and Poltergeist apps used to carry these
// cases through their editor_syntax re-export.
void main() {
  group('search', () {
    test('is case-insensitive by default and reports exact ranges', () {
      final matches = findSearchMatches('Beta beta BETA', 'beta');
      expect(matches, hasLength(3));
      expect(matches.first, const TextRange(start: 0, end: 4));
      expect(matches.last, const TextRange(start: 10, end: 14));
      expect(
        findSearchMatches('Beta beta BETA', 'beta', caseSensitive: true),
        hasLength(1),
      );
    });

    test('caps the match count at the limit', () {
      final text = 'a' * 50;
      expect(findSearchMatches(text, 'a', limit: 10), hasLength(10));
    });

    test('an empty query has no matches', () {
      expect(findSearchMatches('anything', ''), isEmpty);
    });
  });

  group('span building', () {
    test('search hits overlay token colors without splitting order', () {
      const text = 'abcdef';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: const [SyntaxToken(0, 4, SyntaxTokenType.string)],
        matches: const [TextRange(start: 2, end: 6)],
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.dark,
      );
      final texts = spans.map((s) => (s as TextSpan).text).toList();
      expect(texts, ['ab', 'cd', 'ef']);
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(styles[0]?.color, EditorSyntaxTheme.dark.string);
      expect(styles[0]?.backgroundColor, isNull);
      expect(
        styles[1]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(
        styles[2]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(styles[2]?.color, EditorSyntaxTheme.dark.activeMatchForeground);
    });

    test('inactive matches use the plain hit colors', () {
      final spans = buildHighlightedSpans(
        text: 'xx yy',
        tokens: const [],
        matches: const [
          TextRange(start: 0, end: 2),
          TextRange(start: 3, end: 5),
        ],
        activeMatchIndex: 1,
        theme: EditorSyntaxTheme.dark,
      );
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(
        styles.first?.backgroundColor,
        EditorSyntaxTheme.dark.matchBackground,
      );
      expect(
        styles.last?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
    });

    test('reassembles the exact source text', () {
      const text = '# c\nkey: "value" 42\n';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: tokenizeSyntax(text, SyntaxLanguages.yaml),
        matches: findSearchMatches(text, 'e'),
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.light,
      );
      expect(spans.map((s) => (s as TextSpan).text).join(), text);
    });
  });
}

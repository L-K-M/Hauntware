import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/editor_syntax.dart';

// The syntax engine and search live in planchette_core and
// planchette_editor, which own their tests. This file keeps what is
// Poltergeist's: the palette against its theme, and proof that the
// compatibility import still resolves to the shared engine.

void main() {
  test('syntax comments remain readable on both editor backgrounds', () {
    for (final brightness in Brightness.values) {
      final foreground = EditorSyntaxTheme.of(
        brightness,
      ).comment.computeLuminance();
      final background = buildPoltergeistTheme(
        brightness,
      ).scaffoldBackgroundColor.computeLuminance();
      final light = foreground > background ? foreground : background;
      final dark = foreground < background ? foreground : background;
      expect(
        (light + 0.05) / (dark + 0.05),
        greaterThanOrEqualTo(4.5),
        reason: '${brightness.name} comment contrast',
      );
    }
  });

  test('the compatibility import resolves to the shared syntax engine', () {
    expect(syntaxLanguageFor('/srv/deploy.py')?.id, 'python');

    const text = '# note\nkey: "value"\n';
    final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
    expect(
      tokens.where((token) => token.type == SyntaxTokenType.comment),
      hasLength(1),
    );
    expect(findSearchMatches(text, 'KEY'), const [
      TextRange(start: 7, end: 10),
    ]);
  });
}

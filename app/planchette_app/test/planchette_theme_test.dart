import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/theme/planchette_theme.dart';
import 'package:planchette_editor/planchette_editor.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    test('${brightness.name} syntax colors meet WCAG AA everywhere', () {
      final theme = planchetteTheme(brightness);
      final scheme = theme.colorScheme;
      final syntax = theme.extension<EditorSyntaxTheme>()!;
      // The editor's current-line band is the text color at 4.5% opacity.
      final band = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.045),
        scheme.surface,
      );
      final backgrounds = {
        'page': scheme.surface,
        'current line': band,
        'chrome': scheme.surfaceContainerLow,
      };
      final colors = {
        'text': scheme.onSurface,
        'secondary text': scheme.onSurfaceVariant,
        for (final type in SyntaxTokenType.values)
          type.name: syntax.colorFor(type),
      };
      for (final background in backgrounds.entries) {
        for (final color in colors.entries) {
          expect(
            contrast(color.value, background.value),
            greaterThanOrEqualTo(4.5),
            reason: '${color.key} on ${background.key}',
          );
        }
      }
      expect(
        contrast(syntax.activeMatchForeground, syntax.activeMatchBackground),
        greaterThanOrEqualTo(4.5),
      );
      // Ordinary matches are translucent, so check them as composited.
      for (final background in backgrounds.entries) {
        expect(
          contrast(
            syntax.matchForeground,
            Color.alphaBlend(syntax.matchBackground, background.value),
          ),
          greaterThanOrEqualTo(4.5),
          reason: 'match text over ${background.key}',
        );
      }
    });
  }
}

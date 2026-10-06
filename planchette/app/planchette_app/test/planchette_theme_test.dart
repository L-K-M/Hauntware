import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/theme/planchette_theme.dart';
import 'package:planchette_editor/planchette_editor.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// The CIE 1976 difference between two opaque colors; about 2.3 is just
/// noticeable side by side.
double deltaE(Color a, Color b) {
  List<double> lab(Color color) {
    double linear(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    double f(double t) => t > 216 / 24389
        ? math.pow(t, 1 / 3).toDouble()
        : (24389 / 27 * t + 16) / 116;
    final (r, g, b) = (linear(color.r), linear(color.g), linear(color.b));
    final x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
    final y = f(0.2126 * r + 0.7152 * g + 0.0722 * b);
    final z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
    return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
  }

  final (p, q) = (lab(a), lab(b));
  return math.sqrt(
    math.pow(p[0] - q[0], 2) +
        math.pow(p[1] - q[1], 2) +
        math.pow(p[2] - q[2], 2),
  );
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
      // Dialogs and raised chrome sit on the higher containers; only UI text
      // is drawn there.
      for (final raised in {
        'raised chrome': scheme.surfaceContainerHigh,
        'highest chrome': scheme.surfaceContainerHighest,
      }.entries) {
        for (final text in {
          'text': scheme.onSurface,
          'secondary text': scheme.onSurfaceVariant,
        }.entries) {
          expect(
            contrast(text.value, raised.value),
            greaterThanOrEqualTo(4.5),
            reason: '${text.key} on ${raised.key}',
          );
        }
      }
      // Ordinary matches are translucent, so check them as composited, and
      // the text too in case a palette makes it translucent (from #81).
      for (final background in backgrounds.entries) {
        final match = Color.alphaBlend(
          syntax.matchBackground,
          background.value,
        );
        expect(
          contrast(Color.alphaBlend(syntax.matchForeground, match), match),
          greaterThanOrEqualTo(4.5),
          reason: 'match text over ${background.key}',
        );
      }
    });
  }

  for (final brightness in Brightness.values) {
    test('${brightness.name} selection is legible and unlike a match', () {
      final theme = planchetteTheme(brightness);
      final scheme = theme.colorScheme;
      final syntax = theme.extension<EditorSyntaxTheme>()!;
      final page = scheme.surface;
      final selection = Color.alphaBlend(
        theme.textSelectionTheme.selectionColor!,
        page,
      );
      final match = Color.alphaBlend(syntax.matchBackground, page);
      // Selected text and inactive search hits must not look alike.
      expect(deltaE(selection, match), greaterThanOrEqualTo(20));
      expect(deltaE(selection, page), greaterThanOrEqualTo(10));
      // Near black, hue barely registers, so a dark selection must lift
      // the page's lightness: a 1.21:1 indigo passed the distance above
      // and was all but invisible.
      if (brightness == Brightness.dark) {
        expect(contrast(selection, page), greaterThanOrEqualTo(1.5));
      }
      for (final color in [
        scheme.onSurface,
        for (final type in SyntaxTokenType.values) syntax.colorFor(type),
      ]) {
        expect(contrast(color, selection), greaterThanOrEqualTo(4.5));
      }
    });
  }
}

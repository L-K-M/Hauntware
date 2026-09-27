import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// WCAG 2.1 relative luminance contrast ratio between two opaque colors.
double _contrast(Color first, Color second) {
  final a = _luminance(first);
  final b = _luminance(second);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

double _luminance(Color color) {
  // WCAG 2.1 sRGB linearization cutoff.
  double channel(double value) => value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG AA for body text. The buffer is 14px monospace, well under the 18pt
/// (or 14pt bold) that earns the 3:1 large-text allowance.
const double minimumTextContrast = 4.5;

void main() {
  for (final brightness in Brightness.values) {
    // The editor paints no background of its own, so its text sits on the
    // Scaffold it is placed in. Keep this in step with that Scaffold: if the
    // editor ever gets its own canvas color, measure against that instead.
    final surface = planchetteTheme(brightness).scaffoldBackgroundColor;
    final syntax = EditorSyntaxTheme.of(brightness);

    group('${brightness.name} editor surface', () {
      for (final token in {
        'comment': syntax.comment,
        'string': syntax.string,
        'number': syntax.number,
        'keyword': syntax.keyword,
        'meta': syntax.meta,
      }.entries) {
        test('${token.key} is readable on the surface', () {
          expect(
            _contrast(token.value, surface),
            greaterThanOrEqualTo(minimumTextContrast),
          );
        });
      }

      test('a search match is readable on its own highlight', () {
        // The inactive highlight is translucent, so measure the composite the
        // user actually sees: the highlight over the surface, and the text on
        // top of that composite.
        final background = Color.alphaBlend(syntax.matchBackground, surface);
        final foreground = Color.alphaBlend(syntax.matchForeground, background);
        expect(
          _contrast(background, foreground),
          greaterThanOrEqualTo(minimumTextContrast),
        );
      });

      test('the active match is readable on its own highlight', () {
        expect(
          _contrast(syntax.activeMatchBackground, syntax.activeMatchForeground),
          greaterThanOrEqualTo(minimumTextContrast),
        );
      });
    });
  }
}

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// Pins the WCAG 2 math the themes rely on: ratio symmetry and bounds,
/// compositing before measuring translucents, and ink selection.
void main() {
  test('contrastRatio is WCAG 2: symmetric, 1 to 21', () {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    expect(contrastRatio(black, white), moreOrLessEquals(21, epsilon: 0.01));
    expect(contrastRatio(white, black), moreOrLessEquals(21, epsilon: 0.01));
    expect(contrastRatio(white, white), moreOrLessEquals(1, epsilon: 0.001));
    // A known mid pair: the shared light theme's secondary text on its
    // listing surface.
    expect(
      contrastRatio(const Color(0xFF596170), const Color(0xFFFFFFFF)),
      moreOrLessEquals(6.23, epsilon: 0.01),
    );
  });

  test('compositeOver is the colour as drawn on its background', () {
    const background = Color(0xFFF1F2F4);
    final translucent = const Color(0xFF1C1F24).withValues(alpha: 0.06);
    expect(
      compositeOver(translucent, background),
      Color.alphaBlend(translucent, background),
    );
  });

  test('legibleOn picks the ink with the better ratio', () {
    expect(legibleOn(const Color(0xFF000000)), const Color(0xFFFFFFFF));
    expect(legibleOn(const Color(0xFFFFFFFF)), const Color(0xFF000000));
    // WCAG's near-equal point: a mid grey gets black (about 4.7:1 vs
    // white's about 4.5:1).
    expect(legibleOn(const Color(0xFF777777)), const Color(0xFF000000));
  });
}

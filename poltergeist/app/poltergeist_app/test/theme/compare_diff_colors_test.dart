import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/compare_diff_colors.dart';
import 'package:poltergeist_app/theme/contrast.dart';

void main() {
  test('derives the default palette in both brightnesses', () {
    final dark = buildPoltergeistTheme(
      Brightness.dark,
    ).extension<CompareDiffColors>()!;
    final light = buildPoltergeistTheme(
      Brightness.light,
    ).extension<CompareDiffColors>()!;

    // Composited colours carry float channels, so compare their ARGB.
    expect(
      _argb(dark),
      _argb(
        _colors(
          addedFill: 0xFF2C443E,
          removedFill: 0xFF46363C,
          text: 0xFFE7EAEF,
          addedMarker: 0xFF5BD17A,
          removedMarker: 0xFFFF7A70,
          gapFill: 0xFF2D333B,
          activeRegion: 0xFF5CC3AA,
        ),
      ),
    );
    expect(
      _argb(light),
      _argb(
        _colors(
          addedFill: 0xFFE4F1E7,
          removedFill: 0xFFF8E5E5,
          text: 0xFF1C1F24,
          addedMarker: 0xFF1B873A,
          removedMarker: 0xFFC62828,
          gapFill: 0xFFF4F4F4,
          activeRegion: 0xFF1B7563,
        ),
      ),
    );
  });

  test('copyWith replaces one slot', () {
    final base = CompareDiffColors.derive(
      brightness: Brightness.dark,
      surface: const Color(0xFF202020),
      onSurface: const Color(0xFFEEEEEE),
      accent: const Color(0xFF55AAFF),
    );
    final changed = base.copyWith(gapFill: const Color(0xFF123456));

    expect(changed.gapFill, const Color(0xFF123456));
    expect(changed.copyWith(gapFill: base.gapFill), base);
  });

  test('lerp returns the endpoints and blends the midpoint', () {
    final dark = buildPoltergeistTheme(
      Brightness.dark,
    ).extension<CompareDiffColors>()!;
    final light = buildPoltergeistTheme(
      Brightness.light,
    ).extension<CompareDiffColors>()!;

    expect(dark.lerp(light, 0), dark);
    expect(dark.lerp(light, 1), light);
    expect(
      dark.lerp(light, 0.5).addedFill,
      Color.lerp(dark.addedFill, light.addedFill, 0.5),
    );
    expect(dark.lerp(null, 0.5), same(dark));
  });

  test('equal colours are equal with equal hash codes', () {
    CompareDiffColors build() => CompareDiffColors.derive(
      brightness: Brightness.light,
      surface: const Color(0xFFFFFFFF),
      onSurface: const Color(0xFF111111),
      accent: const Color(0xFF0066CC),
    );

    expect(build(), build());
    expect(build().hashCode, build().hashCode);
  });

  testWidgets('of falls back to a derived palette on a bare theme', (
    tester,
  ) async {
    late CompareDiffColors colors;
    final theme = ThemeData(brightness: Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            colors = CompareDiffColors.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(
      colors,
      CompareDiffColors.derive(
        brightness: Brightness.dark,
        surface: theme.colorScheme.surface,
        onSurface: theme.colorScheme.onSurface,
        accent: theme.colorScheme.primary,
      ),
    );
  });

  test('a degenerate palette still derives legible text and marks', () {
    for (final brightness in Brightness.values) {
      const grey = Color(0xFF808080);
      final colors = CompareDiffColors.derive(
        brightness: brightness,
        surface: grey,
        onSurface: grey,
        accent: grey,
      );

      expect(
        contrastRatio(colors.addedText, colors.addedFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(colors.removedText, colors.removedFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(colors.addedMarker, colors.addedFill),
        greaterThanOrEqualTo(3),
      );
      expect(contrastRatio(colors.activeRegion, grey), greaterThanOrEqualTo(3));
    }
  });
}

CompareDiffColors _colors({
  required int addedFill,
  required int removedFill,
  required int text,
  required int addedMarker,
  required int removedMarker,
  required int gapFill,
  required int activeRegion,
}) => CompareDiffColors(
  addedFill: Color(addedFill),
  removedFill: Color(removedFill),
  addedText: Color(text),
  removedText: Color(text),
  addedMarker: Color(addedMarker),
  removedMarker: Color(removedMarker),
  gapFill: Color(gapFill),
  activeRegion: Color(activeRegion),
);

List<int> _argb(CompareDiffColors colors) => [
  for (final color in [
    colors.addedFill,
    colors.removedFill,
    colors.addedText,
    colors.removedText,
    colors.addedMarker,
    colors.removedMarker,
    colors.gapFill,
    colors.activeRegion,
  ])
    color.toARGB32(),
];

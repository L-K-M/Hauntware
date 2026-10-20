import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:seance_terminal/seance_terminal.dart';

void main() {
  test('font sizes clamp to the supported range', () {
    expect(clampTerminalFontSize(2), kMinTerminalFontSize);
    expect(clampTerminalFontSize(99), kMaxTerminalFontSize);
    expect(clampTerminalFontSize(15), 15);
  });

  group('TerminalAppearance.of', () {
    TerminalAppearance of({
      String fontFamily = '',
      double fontSize = kDefaultTerminalFontSize,
      TerminalLigatures ligatures = TerminalLigatures.on,
      TerminalPalette palette = TerminalPalette.followApp,
      ThemeTerminalColors? themeColors,
      Brightness brightness = Brightness.dark,
    }) => TerminalAppearance.of(
      fontSize: fontSize,
      fontFamily: fontFamily,
      ligatures: ligatures,
      palette: palette,
      themeColors: themeColors,
      brightness: brightness,
    );

    test('a blank family draws the default face before the mono stack', () {
      final style = of().style;
      expect(style.fontFamily, kDefaultTerminalFont.family);
      expect(style.fontFamilyFallback, [
        kDefaultTerminalFont.family,
        ...ghostMonoFontFamilies,
      ]);
      expect(of(fontSize: 99).style.fontSize, kMaxTerminalFontSize);
    });

    test('ligatures off asks the default face for none', () {
      expect(of().style.ligatures, TerminalLigatures.on);
      expect(
        of(ligatures: TerminalLigatures.off).style.ligatures,
        TerminalLigatures.off,
      );
    });

    test('following the app uses the built-in palette by brightness', () {
      expect(of().theme, SeanceTerminalThemes.dark);
      expect(
        of(brightness: Brightness.light).theme,
        SeanceTerminalThemes.light,
      );
      expect(of().brightness, Brightness.dark);
    });

    test('a theme\'s own colours win only while following the app', () {
      final colors = SeanceTerminalThemes.toColors(SeanceTerminalThemes.light);
      expect(
        of(themeColors: colors).theme.background,
        SeanceTerminalThemes.light.background,
      );
      expect(
        of(themeColors: colors, palette: TerminalPalette.alwaysDark).theme,
        SeanceTerminalThemes.dark,
      );
    });
  });

  test('toColors and fromColors round-trip the built-in palettes', () {
    for (final theme in [
      SeanceTerminalThemes.dark,
      SeanceTerminalThemes.light,
    ]) {
      final back = SeanceTerminalThemes.fromColors(
        SeanceTerminalThemes.toColors(theme),
      );
      expect(back.background, theme.background);
      expect(back.foreground, theme.foreground);
      expect(back.cursor, theme.cursor);
      expect(back.red, theme.red);
      expect(back.brightWhite, theme.brightWhite);
      // Search hits are derived: matches in yellow, the current one in the
      // cursor colour.
      expect(back.searchHitBackground, theme.yellow);
      expect(back.searchHitBackgroundCurrent, theme.cursor);
    }
  });
}

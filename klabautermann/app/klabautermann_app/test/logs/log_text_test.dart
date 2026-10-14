import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_text.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

LogPalette _palette(Brightness brightness) => LogPalette.fromTheme(
  brightness == Brightness.dark
      ? GhostTheme.dark(klabautermannThemeStyle, platform: TargetPlatform.linux)
      : GhostTheme.light(
          klabautermannThemeStyle,
          platform: TargetPlatform.linux,
        ),
);

/// The contrast [style]'s text has where it is drawn.
double _contrast(TextStyle style, LogPalette palette) =>
    contrastRatio(style.color!, style.backgroundColor ?? palette.background);

void main() {
  test('syslog priorities map to four levels', () {
    final [error, warning, info, debug] = LogLevel.values;
    expect(
      [for (var p = -1; p <= 8; p++) LogLevel.fromSyslogPriority(p)],
      [null, error, error, error, error, warning, info, info, debug, null],
    );
  });

  for (final brightness in Brightness.values) {
    group('LogPalette, ${brightness.name} theme', () {
      final palette = _palette(brightness);

      test('every level colour reads at 4.5:1', () {
        for (final level in [...LogLevel.values, null]) {
          expect(
            contrastRatio(palette.levelColor(level), palette.background),
            greaterThanOrEqualTo(logTextMinContrast),
            reason: '$level',
          );
        }
        expect(
          _contrast(palette.markerStyle, palette),
          greaterThanOrEqualTo(logTextMinContrast),
        );
      });

      test('text that matches its background is lifted to 4.5:1', () {
        SgrStyle on(SgrColor color, {bool faint = false}) =>
            SgrStyle(foreground: color, background: color, faint: faint);
        final hidden = [
          // 30;40, 37;47, 97;107, then equal RGB values at a mid grey (the
          // hardest case), bright black, and faint text.
          on(const SgrPaletteColor(0)),
          on(const SgrPaletteColor(7)),
          on(const SgrPaletteColor(15)),
          on(const SgrRgbColor(119, 119, 119)),
          const SgrStyle(foreground: SgrPaletteColor(8)),
          const SgrStyle(foreground: SgrPaletteColor(0), faint: true),
          const SgrStyle(foreground: SgrPaletteColor(15), faint: true),
        ];
        for (final style in hidden) {
          for (final level in [...LogLevel.values, null]) {
            expect(
              _contrast(palette.styleFor(style, level), palette),
              greaterThanOrEqualTo(logTextMinContrast),
              reason: '$style at $level',
            );
          }
        }
      });

      test('the level colour stands in for the default foreground only', () {
        final error = palette.styleFor(SgrStyle.plain, LogLevel.error);
        expect(error.color, palette.levelColor(LogLevel.error));
        expect(error.color, isNot(palette.levelColor(null)));

        const blue = SgrStyle(foreground: SgrRgbColor(0, 0, 255));
        expect(
          palette.styleFor(blue, LogLevel.error).color,
          palette.styleFor(blue, null).color,
        );
      });

      test('inverse swaps the colours in effect', () {
        final style = palette.styleFor(
          const SgrStyle(inverse: true),
          LogLevel.warning,
        );
        expect(style.backgroundColor, palette.levelColor(LogLevel.warning));
        expect(
          _contrast(style, palette),
          greaterThanOrEqualTo(logTextMinContrast),
        );
      });

      test('attributes become weight, slant and decorations', () {
        final style = palette.styleFor(
          const SgrStyle(
            bold: true,
            italic: true,
            underline: true,
            strikethrough: true,
          ),
          null,
        );
        expect(style.fontWeight, FontWeight.bold);
        expect(style.fontStyle, FontStyle.italic);
        expect(
          style.decoration,
          TextDecoration.combine([
            TextDecoration.underline,
            TextDecoration.lineThrough,
          ]),
        );
        final plain = palette.styleFor(SgrStyle.plain, null);
        expect(plain.fontWeight, isNull);
        expect(plain.backgroundColor, isNull);
      });
    });
  }

  test('palette entries 16 to 255 are the xterm cube and grey ramp', () {
    final palette = _palette(Brightness.light);
    Color background(int index) => palette
        .styleFor(SgrStyle(background: SgrPaletteColor(index)), null)
        .backgroundColor!;

    expect(background(16), const Color(0xFF000000));
    expect(background(196), const Color(0xFFFF0000));
    expect(background(110), const Color(0xFF87AFD7));
    expect(background(231), const Color(0xFFFFFFFF));
    expect(background(232), const Color(0xFF080808));
    expect(background(255), const Color(0xFFEEEEEE));
    expect(
      palette
          .styleFor(const SgrStyle(background: SgrRgbColor(1, 2, 3)), null)
          .backgroundColor,
      const Color(0xFF010203),
    );
  });

  group('logLineSpan', () {
    final palette = _palette(Brightness.light);
    const base = TextStyle(fontSize: 13);

    test('drops escapes and styles each run', () {
      final span = logLineSpan(
        const LogLine(0, 'a\x1b[31mbc\x1b[0m\td'),
        palette: palette,
        base: base,
      );

      expect(span.style, base);
      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['a', 'bc', '\td']);
      expect(
        runs[1].style,
        palette.styleFor(const SgrStyle(foreground: SgrPaletteColor(1)), null),
      );
      expect(runs[0].style, palette.styleFor(SgrStyle.plain, null));
    });

    test('a cut line ends with its note in the marker style', () {
      final span = logLineSpan(
        const LogLine(0, 'abc', originalLength: 20000),
        palette: palette,
        base: base,
        level: LogLevel.error,
        cutNote: '[cut]',
      );

      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['abc', ' [cut]']);
      expect(runs.first.style!.color, palette.levelColor(LogLevel.error));
      expect(runs.last.style, palette.markerStyle);
    });
  });

  test('logTextCells bounds the drawn width in advances', () {
    expect(logTextCells(''), 0);
    expect(logTextCells('abc é'), 5);
    expect(logTextCells('a\tb'), 4);
    expect(logTextCells('日本'), 4, reason: 'wide characters');
    expect(logTextCells('😀'), 4, reason: 'two code units');
  });

  test('logTextCells never fits a line or paragraph separator', () {
    // The text engine breaks the row there, so no width bound holds.
    for (final separator in ['\u2028', '\u2029']) {
      expect(logTextCells('a${separator}b'), greaterThan(1 << 20));
    }
  });
}

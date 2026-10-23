import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/logs/log_level.dart';
import 'package:klabautermann_app/ui/logs/log_text.dart';
import 'package:klabautermann_app/ui/logs/log_tokens.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart'
    show ContainerLine;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart' show TextMatch;

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
        note: '[cut]',
      );

      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['abc', ' [cut]']);
      expect(runs.first.style!.color, palette.levelColor(LogLevel.error));
      expect(runs.last.style, palette.markerStyle);
    });

    test('matches split the runs; the current one is also underlined', () {
      final span = logLineSpan(
        const LogLine(0, '\x1b[31mred\x1b[0m text'),
        palette: palette,
        base: base,
        matches: const [
          TextMatch(start: 1, end: 6),
          TextMatch(start: 6, end: 7),
        ],
        currentMatch: 1,
      );

      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['r', 'ed', ' te', 'x', 't']);
      final red = palette.styleFor(
        const SgrStyle(foreground: SgrPaletteColor(1)),
        null,
      );
      expect(runs[1].style, palette.matchStyle(red, current: false));
      expect(runs[1].style!.decoration, TextDecoration.none);
      expect(runs[3].style!.decoration, TextDecoration.underline);
      expect(
        runs[1].style!.backgroundColor,
        isNot(runs[3].style!.backgroundColor),
      );
    });

    test('only the current match is underlined, even in underlined text', () {
      final span = logLineSpan(
        const LogLine(0, '\x1b[4;9mERROR ERROR\x1b[0m'),
        palette: palette,
        base: base,
        matches: const [
          TextMatch(start: 0, end: 5),
          TextMatch(start: 6, end: 11),
        ],
        currentMatch: 1,
      );

      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['ERROR', ' ', 'ERROR']);
      expect(runs[0].style!.decoration, TextDecoration.lineThrough);
      expect(
        runs[2].style!.decoration,
        TextDecoration.combine([
          TextDecoration.lineThrough,
          TextDecoration.underline,
        ]),
      );
    });
  });

  for (final brightness in Brightness.values) {
    test('match text reads at 4.5:1, ${brightness.name} theme', () {
      final palette = _palette(brightness);
      for (final level in [...LogLevel.values, null]) {
        for (final current in [false, true]) {
          final style = palette.matchStyle(
            palette.styleFor(SgrStyle.plain, level),
            current: current,
          );
          expect(_contrast(style, palette), greaterThanOrEqualTo(4.5));
        }
      }
    });
  }

  group('highlighting (LOG-07)', () {
    for (final brightness in Brightness.values) {
      test('every token colour reads at 4.5:1, ${brightness.name} theme', () {
        final palette = _palette(brightness);
        for (final level in [...LogLevel.values, null]) {
          for (final kind in LogTokenKind.values) {
            final style = palette.tokenStyle(
              palette.styleFor(SgrStyle.plain, level),
              kind,
            );
            expect(
              _contrast(style, palette),
              greaterThanOrEqualTo(logTextMinContrast),
              reason: '$kind at $level',
            );
          }
        }
      });
    }

    final palette = _palette(Brightness.light);
    const base = TextStyle(fontSize: 13);

    test('colours tokens in plain text and keeps the rest of the style', () {
      final span = logLineSpan(
        const LogLine(0, 'GET /a 503 from \x1b[1m10.0.0.1\x1b[0m'),
        palette: palette,
        base: base,
        level: LogLevel.warning,
      );
      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), [
        'GET /a ',
        '503',
        ' from ',
        '10.0.0.1',
      ]);
      final warning = palette.styleFor(SgrStyle.plain, LogLevel.warning);
      expect(runs[0].style, warning);
      expect(
        runs[1].style,
        palette.tokenStyle(warning, LogTokenKind.httpServerError),
      );
      final bold = palette.styleFor(
        const SgrStyle(bold: true),
        LogLevel.warning,
      );
      expect(runs[3].style, palette.tokenStyle(bold, LogTokenKind.ipAddress));
      expect(runs[3].style!.fontWeight, FontWeight.bold);
    });

    test('a token split by an SGR span is coloured on both sides', () {
      final span = logLineSpan(
        const LogLine(0, 'http://a.\x1b[4mtest\x1b[0m/x'),
        palette: palette,
        base: base,
      );
      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['http://a.', 'test', '/x']);
      final url = palette.tokenStyle(
        palette.styleFor(SgrStyle.plain, null),
        LogTokenKind.url,
      );
      expect(runs[0].style, url);
      expect(runs[2].style, url);
      expect(runs[1].style!.color, url.color);
    });

    test("a program's own colours win over a token's", () {
      const red = SgrStyle(foreground: SgrPaletteColor(1));
      final span = logLineSpan(
        const LogLine(0, '\x1b[31mGET /a 200\x1b[0m \x1b[7m10.0.0.1\x1b[0m'),
        palette: palette,
        base: base,
      );
      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['GET /a 200', ' ', '10.0.0.1']);
      expect(runs[0].style, palette.styleFor(red, null));
      expect(
        runs[2].style,
        palette.styleFor(const SgrStyle(inverse: true), null),
      );
    });

    test('a search match over a token keeps the match colours', () {
      final span = logLineSpan(
        const LogLine(0, 'GET /a 404'),
        palette: palette,
        base: base,
        matches: const [TextMatch(start: 7, end: 10)],
        currentMatch: 0,
      );
      final runs = span.children!.cast<TextSpan>();
      expect(runs.last.text, '404');
      expect(runs.last.style!.backgroundColor, isNotNull);
      expect(
        runs.last.style!.decoration!.contains(TextDecoration.underline),
        isTrue,
      );
    });
  });

  group('journal rows (LOG-01)', () {
    LogLine journal(Map<String, String?> fields) =>
        (LogBuffer()..addJournal([JournalEntry(fields)]))[0] as LogLine;

    test('start with the unit and PID that logged them', () {
      expect(
        logRowText(
          journal({
            '_SYSTEMD_UNIT': 'cron.service',
            '_PID': '7',
            'MESSAGE': 'hi',
          }),
        ),
        'cron.service[7]: hi',
      );
      expect(
        logRowText(journal({'SYSLOG_IDENTIFIER': 'kernel', 'MESSAGE': 'hi'})),
        'kernel: hi',
      );
      expect(logRowText(journal({'_PID': '7', 'MESSAGE': 'hi'})), '[7]: hi');
      expect(logRowText(journal({'MESSAGE': 'hi'})), 'hi');
      expect(
        logRowText(const LogLine(0, 'cron.service[7]: hi')),
        'cron.service[7]: hi',
      );
    });

    test('a message\'s newlines are marked and break its row', () {
      expect(
        logRowText(journal({'MESSAGE': 'one\ntwo\r\n\x1b[1mthree'})),
        'one\u23ce\u2028two\u23ce\u2028three',
      );
      expect(logRowText(const LogLine(0, 'one\ntwo')), 'onetwo');
    });

    test('the unit and PID are drawn apart from the message', () {
      final span = logLineSpan(
        journal({'_SYSTEMD_UNIT': 'cron.service', 'MESSAGE': 'hi'}),
        palette: _palette(Brightness.light),
        base: const TextStyle(),
      );

      final runs = span.children!.cast<TextSpan>();
      expect(runs.map((run) => run.text), ['cron.service: ', 'hi']);
      expect(runs.first.style, _palette(Brightness.light).sourceStyle);
    });
  });

  group('container rows (CTX-01)', () {
    const line = LogLine(0, '\x1b[1mready\x1b[0m');
    final at = DateTime(2026, 10, 15, 9, 5, 7, 123);

    test('start with their local time and stream, or spaces for no time', () {
      expect(
        logRowText(
          line,
          container: ContainerLine(ContainerLogStream.stderr, at),
        ),
        '2026-10-15 09:05:07 stderr ready',
      );
      expect(
        logRowText(
          line,
          container: const ContainerLine(ContainerLogStream.stdout, null),
        ),
        '${' ' * 19} stdout ready',
      );
      expect(
        logContainerSourceLength(
          const ContainerLine(ContainerLogStream.stdout, null),
        ),
        '${' ' * 19} stdout '.length,
      );
    });

    test('mark stderr by word, colour and spoken name; stdout plainly', () {
      final palette = _palette(Brightness.light);
      List<TextSpan> runs(
        ContainerLogStream stream, {
        List<TextMatch> matches = const [],
      }) => logLineSpan(
        line,
        palette: palette,
        base: const TextStyle(),
        container: ContainerLine(stream, at),
        streamLabel: stream.name.toUpperCase(),
        matches: matches,
      ).children!.cast<TextSpan>();

      final stderr = runs(ContainerLogStream.stderr);
      expect(stderr.map((run) => run.text), [
        '2026-10-15 09:05:07 ',
        'stderr',
        ' ',
        'ready',
      ]);
      expect(stderr[0].style, palette.sourceStyle);
      expect(stderr[1].style, palette.stderrStyle);
      expect(stderr[1].semanticsLabel, 'STDERR');
      expect(stderr[3].style!.fontWeight, FontWeight.bold);
      expect(
        contrastRatio(palette.stderrStyle.color!, palette.background),
        greaterThanOrEqualTo(logTextMinContrast),
      );

      final stdout = runs(ContainerLogStream.stdout);
      expect(stdout[1].style, palette.sourceStyle);

      // A match across the mark splits it; its name is spoken once.
      final split = runs(
        ContainerLogStream.stderr,
        matches: const [TextMatch(start: 22, end: 25)],
      );
      expect(split.map((run) => run.text), [
        '2026-10-15 09:05:07 ',
        'st',
        'der',
        'r',
        ' ',
        'ready',
      ]);
      expect(split.map((run) => run.semanticsLabel), [
        null,
        'STDERR',
        '',
        '',
        null,
        null,
      ]);
    });
  });

  test('logTextCells bounds the drawn width of Latin-1 text in advances', () {
    expect(logTextCells(''), 0);
    expect(logTextCells('abc é\u00ff'), 6);
    expect(logTextCells('a\tb'), 4);
  });

  test('logTextCells gives no bound for any other unit', () {
    // A fallback font may draw these wider than any count of advances,
    // and the text engine breaks the row at a line or paragraph separator.
    for (final text in ['日本', '😀', 'ok \u2705', 'a\u2e3bb', 'a\u2028b']) {
      expect(logTextCells(text), isNull, reason: text);
    }
  });
}

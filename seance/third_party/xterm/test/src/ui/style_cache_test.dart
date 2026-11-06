import 'dart:ui';

import 'package:flutter/painting.dart' show TextScaler;
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('terminal styles compare by value', () {
    final first = TerminalStyle(
      fontSize: 15,
      height: 1.4,
      fontFamily: 'Test Mono',
      fontFamilyFallback: const ['First fallback', 'Second fallback'],
      ligatures: TerminalLigatures.on,
      fontFeatures: const [FontFeature.enable('liga')],
    );
    final equal = TerminalStyle(
      fontSize: 15,
      height: 1.4,
      fontFamily: 'Test Mono',
      fontFamilyFallback: List.of(first.fontFamilyFallback),
      ligatures: TerminalLigatures.on,
      fontFeatures: List.of(first.fontFeatures!),
    );

    expect(equal, first);
    expect(equal.hashCode, first.hashCode);
    expect(_TerminalStyleSubclass(first), isNot(first));
    expect(first.copyWith(fontSize: 16), isNot(first));
    expect(first.copyWith(height: 1.5), isNot(first));
    expect(first.copyWith(fontFamily: 'Other Mono'), isNot(first));
    expect(
      first.copyWith(fontFamilyFallback: const ['Different fallback']),
      isNot(first),
    );
    expect(first.copyWith(ligatures: TerminalLigatures.off), isNot(first));
    expect(
      first.copyWith(fontFeatures: const [FontFeature.disable('liga')]),
      isNot(first),
    );
  });

  test('terminal themes compare by value', () {
    final theme = TerminalThemes.defaultTheme;
    final equal = _copyTheme(theme);

    expect(equal, theme);
    expect(equal.hashCode, theme.hashCode);
    expect(_TerminalThemeSubclass(theme), isNot(theme));
    expect(_copyTheme(theme, cursor: const Color(0xFF010203)), isNot(theme));
    expect(
      _copyTheme(theme, brightWhite: const Color(0xFF040506)),
      isNot(theme),
    );
    expect(
      _copyTheme(theme, searchHitForeground: const Color(0xFF070809)),
      isNot(theme),
    );
  });

  test('equal appearance keeps paragraph and resolved-style caches', () {
    final style = TerminalStyle(
      fontFamilyFallback: List.of(const TerminalStyle().fontFamilyFallback),
    );
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: style,
      textScaler: TextScaler.noScaling,
    );
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final cell = CellData(
      foreground: CellColor.normal,
      background: CellColor.normal,
      flags: 0,
      content: 'a'.codeUnitAt(0) | (1 << CellContent.widthShift),
    );

    painter.paintCellForeground(canvas, Offset.zero, cell);
    cell.content = 'b'.codeUnitAt(0) | (1 << CellContent.widthShift);
    painter.paintCellForeground(canvas, Offset.zero, cell);

    expect(painter.cachedParagraphCount, 2);
    expect(painter.cachedForegroundStyleCount, 1);

    painter.textStyle = TerminalStyle(
      fontFamilyFallback: List.of(style.fontFamilyFallback),
    );
    painter.theme = _copyTheme(TerminalThemes.defaultTheme);

    expect(painter.cachedParagraphCount, 2);
    expect(painter.cachedForegroundStyleCount, 1);

    painter.textStyle = style.copyWith(fontSize: style.fontSize + 1);

    expect(painter.cachedParagraphCount, 0);
    expect(painter.cachedForegroundStyleCount, 0);
    recorder.endRecording().dispose();
  });
}

class _TerminalStyleSubclass extends TerminalStyle {
  _TerminalStyleSubclass(TerminalStyle style)
      : super(
          fontSize: style.fontSize,
          height: style.height,
          fontFamily: style.fontFamily,
          fontFamilyFallback: style.fontFamilyFallback,
          ligatures: style.ligatures,
          fontFeatures: style.fontFeatures,
        );
}

class _TerminalThemeSubclass extends TerminalTheme {
  _TerminalThemeSubclass(TerminalTheme theme)
      : super(
          cursor: theme.cursor,
          selection: theme.selection,
          foreground: theme.foreground,
          background: theme.background,
          black: theme.black,
          red: theme.red,
          green: theme.green,
          yellow: theme.yellow,
          blue: theme.blue,
          magenta: theme.magenta,
          cyan: theme.cyan,
          white: theme.white,
          brightBlack: theme.brightBlack,
          brightRed: theme.brightRed,
          brightGreen: theme.brightGreen,
          brightYellow: theme.brightYellow,
          brightBlue: theme.brightBlue,
          brightMagenta: theme.brightMagenta,
          brightCyan: theme.brightCyan,
          brightWhite: theme.brightWhite,
          searchHitBackground: theme.searchHitBackground,
          searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
          searchHitForeground: theme.searchHitForeground,
        );
}

TerminalTheme _copyTheme(
  TerminalTheme theme, {
  Color? cursor,
  Color? brightWhite,
  Color? searchHitForeground,
}) {
  return TerminalTheme(
    cursor: cursor ?? theme.cursor,
    selection: theme.selection,
    foreground: theme.foreground,
    background: theme.background,
    black: theme.black,
    red: theme.red,
    green: theme.green,
    yellow: theme.yellow,
    blue: theme.blue,
    magenta: theme.magenta,
    cyan: theme.cyan,
    white: theme.white,
    brightBlack: theme.brightBlack,
    brightRed: theme.brightRed,
    brightGreen: theme.brightGreen,
    brightYellow: theme.brightYellow,
    brightBlue: theme.brightBlue,
    brightMagenta: theme.brightMagenta,
    brightCyan: theme.brightCyan,
    brightWhite: brightWhite ?? theme.brightWhite,
    searchHitBackground: theme.searchHitBackground,
    searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
    searchHitForeground: searchHitForeground ?? theme.searchHitForeground,
  );
}

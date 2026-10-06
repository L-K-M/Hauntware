import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostMenuTheme;
import 'package:planchette_editor/planchette_editor.dart'
    show EditorSyntaxTheme;

/// Planchette's two looks, named for the board it borrows from: Parchment,
/// warm paper and ink, for light mode; Séance, a candle-lit room, for dark.
///
/// Every syntax color keeps at least 4.5:1 contrast (WCAG AA) against the
/// page, the current-line band, the chrome and the selection, and the
/// selection is a cool tint so it never looks like a gold search hit. On
/// Séance the selection is also lighter than the page, since hue alone
/// barely shows near black; `planchette_theme_test.dart` checks all three.
abstract final class PlanchettePalette {
  static const parchment = (
    page: Color(0xFFF7F1E3),
    ink: Color(0xFF2B2522),
    chrome: Color(0xFFEDE3CE),
    chromeHigh: Color(0xFFE3D6BC),
    faded: Color(0xFF665A4E),
    rule: Color(0xFFD6C8AB),
    accent: Color(0xFF8B2E3C),
    selection: Color(0x5961C4D8),
  );

  static const seance = (
    page: Color(0xFF1B1716),
    ink: Color(0xFFEDE3D1),
    chrome: Color(0xFF241F1D),
    chromeHigh: Color(0xFF332C29),
    faded: Color(0xFFB8AA99),
    rule: Color(0xFF3D3431),
    accent: Color(0xFFE6B56A),
    selection: Color(0x66466CB8),
  );

  /// Sepia comments, verdigris strings, brass numbers, oxblood keywords.
  static const parchmentSyntax = EditorSyntaxTheme(
    comment: Color(0xFF6B5C4D),
    string: Color(0xFF2F6B4A),
    number: Color(0xFF8A5410),
    keyword: Color(0xFF8B2E3C),
    meta: Color(0xFF2B5A86),
    matchBackground: Color(0x80E8C87A),
    matchForeground: Color(0xFF2B2522),
    activeMatchBackground: Color(0xFF8B2E3C),
    activeMatchForeground: Color(0xFFFFF8EE),
    searchScopeBackground: Color(0x33E8C87A),
  );

  /// Smoke comments, moss strings, brass numbers, ember keywords.
  static const seanceSyntax = EditorSyntaxTheme(
    comment: Color(0xFFAEA197),
    string: Color(0xFFA3CF8F),
    number: Color(0xFFE6B56A),
    keyword: Color(0xFFF2916A),
    meta: Color(0xFF93BEE3),
    matchBackground: Color(0x55E6B56A),
    matchForeground: Color(0xFFF4EDE2),
    activeMatchBackground: Color(0xFFF2916A),
    activeMatchForeground: Color(0xFF1B1716),
    searchScopeBackground: Color(0x26E6B56A),
  );
}

ThemeData planchetteTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = dark ? PlanchettePalette.seance : PlanchettePalette.parchment;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: brightness,
      ).copyWith(
        primary: palette.accent,
        onPrimary: palette.page,
        surface: palette.page,
        onSurface: palette.ink,
        onSurfaceVariant: palette.faded,
        surfaceContainerLowest: palette.page,
        surfaceContainerLow: palette.chrome,
        surfaceContainer: palette.chrome,
        surfaceContainerHigh: palette.chromeHigh,
        surfaceContainerHighest: palette.chromeHigh,
        outline: palette.faded,
        outlineVariant: palette.rule,
      );
  return GhostMenuTheme.apply(
    ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.page,
      dividerColor: palette.rule,
      dividerTheme: DividerThemeData(color: palette.rule, thickness: 1),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: palette.selection,
        cursorColor: palette.accent,
        selectionHandleColor: palette.accent,
      ),
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      extensions: [
        dark
            ? PlanchettePalette.seanceSyntax
            : PlanchettePalette.parchmentSyntax,
      ],
    ),
  );
}

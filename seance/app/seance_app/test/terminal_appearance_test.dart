import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorLigatures, EditorTextSize;
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/contrast.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

void main() {
  group('terminal appearance', () {
    test('font-specific ligature features reach terminal text shaping', () {
      for (final mode in TerminalLigatures.values) {
        final style = resolveTerminalAppearance(
          AppSettings(terminalFontFamily: 'Geist Mono', terminalLigatures: mode),
          Brightness.dark,
        ).style;
        expect(
          style.toTextStyle().fontFeatures,
          contains(FontFeature('ss11', mode == TerminalLigatures.on ? 1 : 0)),
        );
      }
    });

    test('defaults keep xterm\'s size and draw bundled Iosevka Term', () {
      final appearance = resolveTerminalAppearance(
        AppSettings(),
        Brightness.dark,
      );
      expect(appearance.style.fontSize, kDefaultTerminalFontSize);
      expect(appearance.style.fontFamily, BundledMonoFont.iosevkaTerm.family);
      // The app stack behind it for characters the subset leaves out.
      expect(appearance.style.fontFamilyFallback, [
        BundledMonoFont.iosevkaTerm.family,
        ...SeanceTheme.monoFallback,
      ]);
    });

    test('ligatures follow the setting, on by default', () {
      expect(
        resolveTerminalAppearance(AppSettings(), Brightness.dark)
            .style
            .ligatures,
        TerminalLigatures.on,
      );
      expect(
        resolveTerminalAppearance(
          AppSettings(terminalLigatures: TerminalLigatures.off),
          Brightness.dark,
        ).style.ligatures,
        TerminalLigatures.off,
      );
    });

    test("a bundled font's name draws the bundled copy", () {
      final appearance = resolveTerminalAppearance(
        AppSettings(terminalFontFamily: ' fira code'),
        Brightness.dark,
      );
      expect(appearance.style.fontFamily, BundledMonoFont.firaCode.family);
      expect(
        appearance.style.fontFamilyFallback.sublist(1),
        SeanceTheme.monoFallback,
      );
    });

    test('a chosen family leads, with the app stack behind it', () {
      final appearance = resolveTerminalAppearance(
        AppSettings(terminalFontFamily: '  Iosevka  '),
        Brightness.dark,
      );
      expect(appearance.style.fontFamily, 'Iosevka');
      expect(appearance.style.fontFamilyFallback.first, 'Iosevka');
      // The bundled stack still backs it up for glyphs Iosevka lacks.
      expect(
        appearance.style.fontFamilyFallback.sublist(1),
        SeanceTheme.monoFallback,
      );
    });

    test('followApp tracks the ambient brightness', () {
      // Séance's palette has no terminal of its own, so the built-in
      // light and dark terminals stand in for it.
      final settings = AppSettings(
        terminalPalette: TerminalPalette.followApp,
        themePalette: ThemePresets.seance,
      );
      expect(
        resolveTerminalAppearance(settings, Brightness.dark).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        resolveTerminalAppearance(settings, Brightness.light).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('a new device\'s terminal is the Terminal preset\'s', () {
      final terminal = ThemePresets.terminal.terminal!;
      for (final brightness in Brightness.values) {
        final theme = resolveTerminalAppearance(
          AppSettings(),
          brightness,
        ).theme;
        expect(theme.background, terminal.background, reason: '$brightness');
        expect(theme.foreground, terminal.foreground, reason: '$brightness');
      }
    });

    test('a pinned palette ignores the ambient brightness', () {
      final dark = AppSettings(terminalPalette: TerminalPalette.alwaysDark);
      final light = AppSettings(terminalPalette: TerminalPalette.alwaysLight);
      expect(
        resolveTerminalAppearance(dark, Brightness.light).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        resolveTerminalAppearance(light, Brightness.dark).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('brightness is derived from the resolved background', () {
      final dark = resolveTerminalAppearance(
        AppSettings(terminalPalette: TerminalPalette.alwaysDark),
        Brightness.light,
      );
      final light = resolveTerminalAppearance(
        AppSettings(terminalPalette: TerminalPalette.alwaysLight),
        Brightness.dark,
      );
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
    });

    test('following the app, a theme with terminal colours uses them', () {
      final colors = ThemePresets.solarized.terminal!;
      final settings = AppSettings(themePalette: ThemePresets.solarized);
      for (final brightness in Brightness.values) {
        final theme = resolveTerminalAppearance(settings, brightness).theme;
        expect(theme.background, colors.background);
        expect(theme.foreground, colors.foreground);
        expect(theme.cursor, colors.cursor);
        expect(theme.selection, colors.selection);
        expect(theme.red, colors.ansi[1]);
        expect(theme.brightWhite, colors.ansi[15]);
        // Search highlights, which a theme does not name, are derived.
        expect(theme.searchHitBackground, colors.ansi[3]);
        expect(theme.searchHitBackgroundCurrent, colors.cursor);
        expect([
          colors.background,
          colors.foreground,
        ], contains(theme.searchHitForeground));
      }
    });

    test('search hits keep their text readable on every preset', () {
      for (final preset in ThemePresets.all) {
        final colors = preset.terminal;
        if (colors == null) continue;
        final theme = SeanceTerminalThemes.fromColors(colors);
        for (final hit in [
          theme.searchHitBackground,
          theme.searchHitBackgroundCurrent,
        ]) {
          expect(
            contrastRatio(theme.searchHitForeground, hit),
            greaterThanOrEqualTo(3),
            reason: preset.name,
          );
        }
      }
    });

    test('the lighter of the two base colours is not forced onto a hit', () {
      // A light theme whose yellow and cursor are pale: its near-white
      // background would vanish on them, its dark text does not.
      final colors = ThemePresets.paper.terminal!;
      final pale = ThemeTerminalColors(
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF1A1A1A),
        cursor: const Color(0xFFE0E0E0),
        selection: colors.selection,
        ansi: [
          for (var i = 0; i < ThemeTerminalColors.ansiCount; i++)
            i == ThemeTerminalColors.yellowIndex
                ? const Color(0xFFFFF59D)
                : colors.ansi[i],
        ],
      );
      expect(
        SeanceTerminalThemes.fromColors(pale).searchHitForeground,
        const Color(0xFF1A1A1A),
      );
    });

    test('a pinned palette ignores the theme\'s terminal colours', () {
      final dark = AppSettings(
        themePalette: ThemePresets.paper,
        terminalPalette: TerminalPalette.alwaysDark,
      );
      expect(
        resolveTerminalAppearance(dark, Brightness.light).theme.background,
        SeanceTerminalThemes.dark.background,
      );
    });

    test('a theme without terminal colours keeps the built-in ones', () {
      final settings = AppSettings(themePalette: ThemePresets.graphite);
      expect(
        resolveTerminalAppearance(settings, Brightness.dark).theme,
        same(SeanceTerminalThemes.dark),
      );
    });

    test('the built-in palettes convert to theme colours and back', () {
      for (final builtIn in [
        SeanceTerminalThemes.dark,
        SeanceTerminalThemes.light,
      ]) {
        final colors = SeanceTerminalThemes.toColors(builtIn);
        expect(colors.ansi, hasLength(ThemeTerminalColors.ansiCount));
        final back = SeanceTerminalThemes.fromColors(colors);
        List<Color> named(TerminalTheme t) => [
          t.background,
          t.foreground,
          t.cursor,
          t.selection,
          t.black,
          t.red,
          t.green,
          t.yellow,
          t.blue,
          t.magenta,
          t.cyan,
          t.white,
          t.brightBlack,
          t.brightRed,
          t.brightGreen,
          t.brightYellow,
          t.brightBlue,
          t.brightMagenta,
          t.brightCyan,
          t.brightWhite,
        ];
        expect(named(back), named(builtIn));
      }
    });

    test('font size is clamped when resolving', () {
      expect(
        resolveTerminalAppearance(
          AppSettings(terminalFontSize: 900),
          Brightness.dark,
        ).style.fontSize,
        kMaxTerminalFontSize,
      );
      expect(
        resolveTerminalAppearance(
          AppSettings(terminalFontSize: 1),
          Brightness.dark,
        ).style.fontSize,
        kMinTerminalFontSize,
      );
    });
  });

  group('appearance persistence', () {
    test('round-trips through JSON', () {
      final settings = AppSettings(
        terminalFontSize: 17,
        terminalFontFamily: 'Fira Code',
        terminalPalette: TerminalPalette.alwaysLight,
        terminalLigatures: TerminalLigatures.off,
      );
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.terminalFontSize, 17);
      expect(restored.terminalFontFamily, 'Fira Code');
      expect(restored.terminalPalette, TerminalPalette.alwaysLight);
      expect(restored.terminalLigatures, TerminalLigatures.off);
    });

    test('an out-of-range or unknown stored value falls back safely', () {
      final restored = AppSettings.fromJson({
        'terminalFontSize': 400,
        'terminalPalette': 'nonsense',
        'terminalLigatures': 'nonsense',
      });
      expect(restored.terminalFontSize, kMaxTerminalFontSize);
      expect(restored.terminalPalette, TerminalPalette.followApp);
      expect(restored.terminalLigatures, TerminalLigatures.on);
    });

    test('the editor text size round-trips and is clamped on read', () {
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(AppSettings(editorFontSize: 22).toJson()))
            as Map<String, dynamic>,
      );
      expect(restored.editorFontSize, 22);
      expect(
        AppSettings.fromJson({'editorFontSize': 400}).editorFontSize,
        EditorTextSize.maximum,
      );
      expect(
        AppSettings.fromJson({'editorFontSize': 'big'}).editorFontSize,
        EditorTextSize.standard,
      );
    });

    test('the editor font round-trips, and a bad value falls back', () {
      final restored = AppSettings.fromJson(
        jsonDecode(
              jsonEncode(
                AppSettings(
                  editorFontFamily: 'Maple Mono',
                  editorLigatures: EditorLigatures.off,
                ).toJson(),
              ),
            )
            as Map<String, dynamic>,
      );
      expect(restored.editorFontFamily, 'Maple Mono');
      expect(restored.editorLigatures, EditorLigatures.off);

      final bad = AppSettings.fromJson({
        'editorFontFamily': 7,
        'editorLigatures': 'nonsense',
      });
      expect(bad.editorFontFamily, isEmpty);
      expect(bad.editorLigatures, EditorLigatures.on);
    });

    test('a settings file written before this feature keeps the default', () {
      final restored = AppSettings.fromJson({'deviceId': 'abc'});
      expect(restored.editorFontSize, EditorTextSize.standard);
      expect(restored.editorFontFamily, isEmpty);
      expect(restored.editorLigatures, EditorLigatures.on);
      expect(restored.terminalFontSize, kDefaultTerminalFontSize);
      expect(restored.terminalFontFamily, isEmpty);
      expect(restored.terminalPalette, TerminalPalette.followApp);
      // Ligatures on: the bundled fonts draw them, and nobody turned them off.
      expect(restored.terminalLigatures, TerminalLigatures.on);
    });
  });
}

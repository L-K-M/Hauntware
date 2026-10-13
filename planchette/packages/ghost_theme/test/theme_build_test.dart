import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show FamilyPalette, GhostFileTheme, SidebarThemeTokens, contrastRatio;

import 'support/host_styles.dart';

/// The theme as it was built before palettes existed, from the tables as
/// they were then, written out here so the comparison below cannot drift
/// with the code it checks. An install that has never opened Appearance
/// must see exactly this.
ColorScheme _legacyScheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color pick(int onDark, int onLight) => Color(dark ? onDark : onLight);
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF6B5BD2),
    brightness: brightness,
  ).copyWith(
    surface: pick(0xFF232932, 0xFFFFFFFF),
    surfaceContainerLowest: pick(0xFF1C2128, 0xFFFFFFFF),
    surfaceContainerLow: pick(0xFF2A313B, 0xFFF1F2F4),
    surfaceContainer: pick(0xFF2D3440, 0xFFF6F6F8),
    surfaceContainerHigh: pick(0xFF353D49, 0xFFEBECEF),
    surfaceContainerHighest: pick(0xFF3B4452, 0xFFE2E5EA),
    onSurface: pick(0xFFE7EAEF, 0xFF1C1F24),
    onSurfaceVariant: pick(0xFFB4BCC8, 0xFF596170),
    outline: pick(0xFF6B7584, 0xFF7D8591),
    outlineVariant: pick(0xFF3A424E, 0xFFDADDE3),
    inverseSurface: pick(0xFFE7EAEF, 0xFF2D323A),
    onInverseSurface: pick(0xFF232932, 0xFFF1F2F4),
    primary: pick(0xFFADA1FF, 0xFF5847C2),
    onPrimary: pick(0xFF1D1452, 0xFFFFFFFF),
    primaryContainer: pick(0xFF43388F, 0xFFE6E0FF),
    onPrimaryContainer: pick(0xFFE6E0FF, 0xFF1D1452),
    secondaryContainer: pick(0xFF3B4758, 0xFFDCE3EC),
    onSecondaryContainer: pick(0xFFDCE4EF, 0xFF18222E),
  );
}

void main() {
  group('the Séance palette draws what the app always drew', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
      for (final brightness in Brightness.values) {
        test('${brightness.name} on ${platform.name}', () {
          final theme = brightness == Brightness.dark
              ? GhostTheme.dark(seanceStyle, platform: platform)
              : GhostTheme.light(seanceStyle, platform: platform);
          final scheme = _legacyScheme(brightness);
          final desktop = platform == TargetPlatform.macOS;
          final plain = ThemeData(
            colorScheme: scheme,
            useMaterial3: true,
            platform: platform,
          );

          expect(theme.brightness, brightness);
          expect(theme.colorScheme, scheme);
          expect(theme.scaffoldBackgroundColor, scheme.surface);
          expect(theme.dividerColor, scheme.outlineVariant);
          expect(theme.hoverColor, scheme.onSurface.withValues(alpha: 0.06));
          expect(theme.visualDensity, VisualDensity.comfortable);
          if (desktop) {
            // The sibling apps' 13 px desktop ramp over Material's styles.
            final t = theme.textTheme;
            expect(
              [
                t.titleLarge,
                t.titleMedium,
                t.titleSmall,
                t.bodyLarge,
                t.bodyMedium,
                t.bodySmall,
                t.labelLarge,
                t.labelMedium,
                t.labelSmall,
              ].map((style) => style?.fontSize),
              [17, 14, 13, 14, 13, 12, 13, 12, 11],
            );
            expect(t.displayLarge, plain.textTheme.displayLarge);
            expect(
              t.bodyMedium?.fontFamily,
              plain.textTheme.bodyMedium?.fontFamily,
            );
          } else {
            expect(theme.textTheme, plain.textTheme);
          }
          expect(
            theme.menuTheme.style?.shape?.resolve({}),
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          );
          expect(
            (theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
            BorderRadius.circular(6),
          );
          // Every component the corner scale can reach keeps Material's own
          // shape at the designed scale.
          expect(theme.dialogTheme, plain.dialogTheme);
          expect(theme.cardTheme, plain.cardTheme);
          if (desktop) {
            // GhostMenuTheme's shared compact skin: 8 px scaled corners,
            // a 4 px panel inset, 13 px labels.
            expect(
              theme.popupMenuTheme.shape,
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            );
            expect(
              theme.popupMenuTheme.menuPadding,
              const EdgeInsets.symmetric(vertical: 4),
            );
            expect(theme.popupMenuTheme.textStyle?.fontSize, 13);
          } else {
            expect(theme.popupMenuTheme, plain.popupMenuTheme);
          }
          expect(theme.inputDecorationTheme, plain.inputDecorationTheme);
          expect(theme.filledButtonTheme, plain.filledButtonTheme);
          expect(theme.outlinedButtonTheme, plain.outlinedButtonTheme);
          expect(theme.textButtonTheme, plain.textButtonTheme);
          expect(theme.segmentedButtonTheme, plain.segmentedButtonTheme);
          expect(theme.chipTheme, plain.chipTheme);
          expect(theme.bottomSheetTheme, plain.bottomSheetTheme);
          expect(theme.snackBarTheme, plain.snackBarTheme);

          final chrome = theme.extension<GhostChrome>()!;
          expect(chrome.sidebarBackground, scheme.surfaceContainerLow);
          expect(chrome.headerBackground, scheme.surfaceContainer);
          expect(chrome.paneBackground, scheme.surface);
          expect(chrome.inspectorBackground, scheme.surfaceContainerLow);
          expect(chrome.separator, scheme.outlineVariant);
          expect(chrome.hoverFill, scheme.onSurface.withValues(alpha: 0.06));
          expect(chrome.capsuleFill, scheme.surfaceContainerHigh);
          expect(chrome.selectionFill, const Color(0xFF5A4BC0));
          expect(chrome.onSelection, const Color(0xFFFFFFFF));
          expect(chrome.inactiveSelectionFill, scheme.surfaceContainerHighest);
          expect(chrome.activePaneIndicator, scheme.primary);
          expect(chrome.secondaryText, scheme.onSurfaceVariant);
          expect(chrome.headerHeight, desktop ? 52 : 56);
          expect(chrome.rowExtent, desktop ? 22 : 48);
          expect(chrome.sidebarRowExtent, desktop ? 26 : 40);
          expect(chrome.cornerScale, 1);

          final light = brightness == Brightness.light;
          expect(
            chrome.statusConnected,
            Color(light ? 0xFF1A7F37 : 0xFF3FB950),
          );
          expect(chrome.statusFailed, Color(light ? 0xFFCF222E : 0xFFFF7B72));
          expect(
            chrome.statusConnecting,
            Color(light ? 0xFFB06E00 : 0xFFD29922),
          );
          expect(chrome.statusUnknown, Color(light ? 0xFF57606A : 0xFF8B949E));
        });
      }
    }

    test('the MaterialApp gets both, following the system', () {
      final themes = GhostTheme.forAppearance(
        seanceStyle,
        AppAppearance(palette: seancePresets.brand),
      );
      expect(themes.themeMode, ThemeMode.system);
      expect(themes.theme.colorScheme, _legacyScheme(Brightness.light));
      expect(themes.darkTheme.colorScheme, _legacyScheme(Brightness.dark));
    });
  });

  test('a new device is drawn in Terminal, whatever the system says', () {
    final themes = GhostTheme.forAppearance(
      seanceStyle,
      AppAppearance(palette: seancePresets.initial),
    );
    expect(themes.theme, same(themes.darkTheme));
    expect(themes.theme.brightness, Brightness.dark);
    expect(themes.theme.colorScheme.surface, seancePresets.terminal.surface);
    expect(themes.theme.colorScheme.primary, seancePresets.terminal.accent);
  });

  group('a palette lands where it says', () {
    test('every slot reaches the scheme and the chrome', () {
      final palette = ThemePalette(
        accent: const Color(0xFF2266CC),
        surface: const Color(0xFF101418),
        sidebar: const Color(0xFF0C1014),
        raised: const Color(0xFF182028),
        text: const Color(0xFFEEF2F6),
        secondaryText: const Color(0xFFA0A8B0),
        hairline: const Color(0x40FFFFFF),
        selection: const Color(0xFF1B4F8F),
        online: const Color(0xFF00E676),
        offline: const Color(0xFFFF5252),
        connecting: const Color(0xFFFFD740),
        unknown: const Color(0xFF90A4AE),
      );
      final theme = GhostTheme.build(seanceStyle, palette, Brightness.light);
      final scheme = theme.colorScheme;
      final chrome = theme.extension<GhostChrome>()!;

      // A dark surface of its own makes the theme dark, whatever was asked.
      expect(theme.brightness, Brightness.dark);
      expect(scheme.primary, palette.accent);
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.surface, palette.surface);
      expect(theme.scaffoldBackgroundColor, palette.surface);
      expect(chrome.paneBackground, palette.surface);
      expect(scheme.surfaceContainerLow, palette.sidebar);
      expect(chrome.sidebarBackground, palette.sidebar);
      expect(chrome.inspectorBackground, palette.sidebar);
      expect(scheme.surfaceContainer, palette.raised);
      expect(chrome.headerBackground, palette.raised);
      expect(scheme.onSurface, palette.text);
      expect(scheme.onSurfaceVariant, palette.secondaryText);
      expect(chrome.secondaryText, palette.secondaryText);
      expect(scheme.outlineVariant, palette.hairline);
      expect(chrome.separator, palette.hairline);
      expect(theme.dividerColor, palette.hairline);
      expect(chrome.selectionFill, palette.selection);
      expect(chrome.activePaneIndicator, palette.accent);
      expect(chrome.statusConnected, palette.online);
      expect(chrome.statusFailed, palette.offline);
      expect(chrome.statusConnecting, palette.connecting);
      expect(chrome.statusUnknown, palette.unknown);
      expect(theme.textTheme.bodyMedium?.color, palette.text);
    });

    test('Automatic shades follow a surface of its own, in order', () {
      final palette = ThemePalette(
        accent: const Color(0xFF8C5729),
        surface: const Color(0xFFFAF5E8),
        text: const Color(0xFF29241C),
      );
      final scheme = GhostTheme.build(
        seanceStyle,
        palette,
        Brightness.dark,
      ).colorScheme;
      expect(scheme.brightness, Brightness.light);
      // Each step further from the surface toward the text: the fraction
      // of the way from one to the other, which is negative for a shade
      // that stepped away from the text instead.
      final surface = scheme.surface.computeLuminance();
      final text = palette.text!.computeLuminance();
      double towardText(Color c) =>
          (c.computeLuminance() - surface) / (text - surface);
      final ladder = [
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ].map(towardText).toList();
      expect(ladder.first, greaterThan(0));
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i], greaterThan(ladder[i - 1]), reason: 'step $i');
      }
      // Mixed from the palette's own colours, not the slate tables.
      expect(scheme.surfaceContainerLow, isNot(const Color(0xFFF1F2F4)));
      expect(scheme.inverseSurface, palette.text);
    });

    test('a light selection gets a dark label', () {
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.highContrast,
        Brightness.light,
      );
      expect(
        theme.extension<GhostChrome>()!.onSelection,
        const Color(0xFF000000),
      );
    });

    test('another accent gets a selection white text reads on', () {
      final chrome = GhostTheme.build(
        seanceStyle,
        seancePresets.brand.copyWith(accent: const Color(0xFF7FD1FF)),
        Brightness.dark,
      ).extension<GhostChrome>()!;
      expect(chrome.onSelection, const Color(0xFFFFFFFF));
      expect(chrome.selectionFill, isNot(const Color(0xFF5A4BC0)));
      expect(
        contrastRatio(chrome.onSelection, chrome.selectionFill),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('brightness', () {
    test('a surface of its own is one theme for the MaterialApp', () {
      final themes = GhostTheme.forAppearance(
        seanceStyle,
        AppAppearance(
          palette: seancePresets.midnight,
          mode: ThemeModePreference.light,
        ),
      );
      expect(themes.theme.brightness, Brightness.dark);
      expect(themes.darkTheme.brightness, Brightness.dark);
      expect(themes.theme.colorScheme.surface, seancePresets.midnight.surface);
    });

    test('the mode picks between the two otherwise', () {
      ThemeMode modeFor(ThemeModePreference mode) => GhostTheme.forAppearance(
        seanceStyle,
        AppAppearance(palette: seancePresets.graphite, mode: mode),
      ).themeMode;
      expect(modeFor(ThemeModePreference.system), ThemeMode.system);
      expect(modeFor(ThemeModePreference.light), ThemeMode.light);
      expect(modeFor(ThemeModePreference.dark), ThemeMode.dark);
    });
  });

  group('shape and type', () {
    test('the corner scale reaches the components and the chrome', () {
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.brand.copyWith(cornerScale: 0.5),
        Brightness.light,
        platform: TargetPlatform.linux,
      );
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );
      // The shared desktop menu skin (GhostMenuTheme.apply) clamps its
      // corners to an 8 px minimum, so it alone does not follow the scale
      // below 1; every other component keeps the scaled radius.
      expect(
        theme.menuTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );
      expect(
        (theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(3),
      );
      expect(
        theme.filledButtonTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
      expect(
        theme.chipTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      final chrome = theme.extension<GhostChrome>()!;
      expect(chrome.cornerScale, 0.5);
      expect(chrome.corner(6), 3);
    });

    test('square is square', () {
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.terminal,
        Brightness.dark,
      );
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      );
    });

    test('a square theme keeps rounded desktop menus', () {
      // The Terminal preset's cornerScale is 0 — square panels everywhere —
      // but the shared menu skin clamps desktop menu corners to an 8 px
      // minimum, for both popup routes and MenuAnchor panels.
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.terminal,
        Brightness.dark,
        platform: TargetPlatform.linux,
      );
      expect(
        theme.popupMenuTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );
      expect(
        theme.menuTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );
    });

    test('the interface font reaches the text theme', () {
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.brand.withFontFamily('Inter'),
        Brightness.light,
        platform: TargetPlatform.linux,
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.titleLarge?.fontFamily, 'Inter');
      // The desktop ramp survives it.
      expect(theme.textTheme.bodyMedium?.fontSize, 13);
    });
  });

  // The shared sidebar kit reads GhostChrome only through these tokens.
  // Read the extension itself: SidebarThemeTokens.of falls back to values
  // equal to the default chrome, so it would hide a missing extension.
  test('the sidebar kit tokens mirror GhostChrome', () {
    final scaled = seancePresets.brand.copyWith(cornerScale: 0.5);
    for (final palette in [...seancePresets.all, scaled]) {
      for (final brightness in Brightness.values) {
        for (final platform in const [
          TargetPlatform.macOS,
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.android,
          TargetPlatform.iOS,
        ]) {
          final theme = GhostTheme.build(
            seanceStyle,
            palette,
            brightness,
            platform: platform,
          );
          final where = '${palette.name} $brightness $platform';
          final chrome = theme.extension<GhostChrome>()!;
          final tokens = theme.extension<SidebarThemeTokens>();
          expect(tokens, isNotNull, reason: where);
          expect(
            tokens!.sidebarBackground,
            chrome.sidebarBackground,
            reason: where,
          );
          expect(tokens.separator, chrome.separator, reason: where);
          expect(tokens.hoverFill, chrome.hoverFill, reason: where);
          expect(tokens.capsuleFill, chrome.capsuleFill, reason: where);
          expect(
            tokens.inactiveSelectionFill,
            chrome.inactiveSelectionFill,
            reason: where,
          );
          expect(tokens.secondaryText, chrome.secondaryText, reason: where);
          expect(
            tokens.sidebarRowExtent,
            chrome.sidebarRowExtent,
            reason: where,
          );
          expect(tokens.cornerScale, chrome.cornerScale, reason: where);
          // Not the constructor's default of 1 by coincidence.
          if (identical(palette, scaled)) {
            expect(tokens.cornerScale, 0.5, reason: where);
          }
        }
      }
    }
  });

  // The extensions the shared chrome is built alongside: a host that reads
  // any of these (the sidebar kit, the file listings, the family hues)
  // falls back to a same-looking default without it, so a missing install
  // would hide here rather than fail.
  test('the shared extensions are all installed', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
      final theme = GhostTheme.build(
        seanceStyle,
        seancePresets.brand,
        Brightness.dark,
        platform: platform,
      );
      expect(theme.extension<GhostChrome>(), isNotNull, reason: platform.name);
      expect(
        theme.extension<SidebarThemeTokens>(),
        isNotNull,
        reason: platform.name,
      );
      expect(
        theme.extension<GhostFileTheme>(),
        isNotNull,
        reason: platform.name,
      );
      expect(
        theme.extension<FamilyPalette>(),
        isNotNull,
        reason: platform.name,
      );
    }
  });

  testWidgets('status colours come from the theme', (tester) async {
    late Color online;
    await tester.pumpWidget(
      MaterialApp(
        theme: GhostTheme.build(
          seanceStyle,
          seancePresets.midnight,
          Brightness.light,
        ),
        home: Builder(
          builder: (context) {
            online = GhostChrome.of(context, seanceStyle).statusConnected;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(online, seancePresets.midnight.online);
  });
}

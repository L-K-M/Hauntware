// Poltergeist's theme builder moved to `ghost_theme`, shared with the rest
// of the Ghost app family (design docs/design/ghost-theme.md). This is the
// app-side façade the rest of Poltergeist still names: the brand seed and
// monospace stack, the [PoltergeistChrome] typedef over the shared
// [GhostChrome], the desktop-platform check, and the builders bound to
// [poltergeistThemeStyle]. The compare view's [CompareDiffColors] stays
// app-side and is appended to the shared build.
import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart'
    show ghostMonoFontFamilies, ghostMonoFontFamily;
import 'package:ghost_theme/ghost_theme.dart';

import 'compare_diff_colors.dart';
import 'theme_presets.dart';

export 'theme_presets.dart' show poltergeistThemeStyle;

const _seedColor = Color(0xFF3D8A78);

/// The colour the scheme seeds from, public for the places that draw it
/// directly rather than through the scheme: the server editor's custom
/// colour picker starts from it when no accent is in force, and it is the
/// default theme preset's accent.
const poltergeistSeedColor = _seedColor;

/// The app's monospace family stack — the family's shared stack: bundled
/// JetBrains Mono, then the cross-platform fallbacks (a bare 'monospace'
/// does not resolve on every platform, notably macOS/iOS). Also the
/// built-in editor's `monoFontFallback` seam value (06 §2.3).
const poltergeistMonoFontFamilies = ghostMonoFontFamilies;

const poltergeistMonoTextStyle = TextStyle(
  fontFamily: ghostMonoFontFamily,
  fontFamilyFallback: poltergeistMonoFontFamilies,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// Poltergeist's name for the shared chrome extension (design
/// docs/design/ghost-theme.md). Its `of` takes the app's style, since a
/// context with no installed extension falls back to the brand table.
typedef PoltergeistChrome = GhostChrome;

/// Whether [platform] gets the desktop density tokens (13 px text, 22 px
/// rows) — touch platforms keep Material's touch-sized defaults (D32 §9).
/// The shared builder's check, under Poltergeist's name.
bool isDesktopPlatform(TargetPlatform platform) =>
    isGhostDesktopPlatform(platform);

/// Poltergeist's theme in the Poltergeist preset: the teal accent over the
/// sibling tables, unchanged, at either brightness. [platform] overrides
/// the host platform the type ramp and row extents are chosen for.
ThemeData buildPoltergeistTheme(
  Brightness brightness, {
  TargetPlatform? platform,
}) => buildPoltergeistThemeFor(
  ThemePresets.poltergeist,
  brightness,
  platform: platform,
);

/// The three theme arguments of a MaterialApp drawn in [appearance].
///
/// A palette with its own surface is one theme, at that surface's
/// brightness, whatever the system or the mode says; otherwise a light and
/// a dark one, picked between by the mode.
({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
poltergeistThemesFor(
  AppAppearance appearance, {
  TargetPlatform? platform,
}) {
  final palette = appearance.palette;
  if (palette.surface != null) {
    final theme = buildPoltergeistThemeFor(
      palette,
      Brightness.light,
      platform: platform,
    );
    return (theme: theme, darkTheme: theme, themeMode: ThemeMode.light);
  }
  return (
    theme: buildPoltergeistThemeFor(
      palette,
      Brightness.light,
      platform: platform,
    ),
    darkTheme: buildPoltergeistThemeFor(
      palette,
      Brightness.dark,
      platform: platform,
    ),
    themeMode: switch (appearance.mode) {
      ThemeModePreference.system => ThemeMode.system,
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
    },
  );
}

/// What every slot of [palette] draws as when its Automatic colours follow
/// [brightness]: the colour an Automatic slot stands for right now, which is
/// where the Appearance section starts a slot that stops being Automatic,
/// and what a preset's swatch shows.
Map<ThemeSlot, Color> resolvedThemeSlots(
  ThemePalette palette,
  Brightness brightness,
) => GhostTheme.resolvedSlots(poltergeistThemeStyle, palette, brightness);

/// [palette] as a theme. [brightness] is what its Automatic colours follow
/// (the system's, or the mode's); a palette that sets its own surface is
/// drawn at that surface's brightness instead (see [resolveBrightness]).
///
/// The shared [GhostTheme.build] paints the neutrals, chrome and menu skin;
/// the compare view's [CompareDiffColors] is app-side and is appended here.
ThemeData buildPoltergeistThemeFor(
  ThemePalette palette,
  Brightness brightness, {
  TargetPlatform? platform,
}) {
  final theme = GhostTheme.build(
    poltergeistThemeStyle,
    palette,
    brightness,
    platform: platform,
  );
  final scheme = theme.colorScheme;
  return theme.copyWith(
    // Poltergeist's pre-theme builder passed the drawn brightness to
    // ThemeData, which turns the dark elevation overlay on; the shared
    // builder leaves it to the constructor's default. Restore the app's
    // legacy value so an install that never opened Appearance is
    // unchanged (the whole-ThemeData gate in theme_build_test.dart).
    applyElevationOverlayColor: theme.brightness == Brightness.dark,
    extensions: [
      ...theme.extensions.values,
      CompareDiffColors.derive(
        brightness: theme.brightness,
        surface: scheme.surface,
        onSurface: scheme.onSurface,
        accent: scheme.primary,
      ),
    ],
  );
}

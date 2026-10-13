import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart';

import 'theme/theme_presets.dart';

export 'theme/theme_presets.dart' show seanceThemeStyle;

/// Séance's name for the shared chrome extension (design
/// docs/design/ghost-theme.md, F4b PR 2). Its `of` takes the app's style,
/// since a context with no installed extension falls back to the brand
/// table.
typedef SeanceChrome = GhostChrome;

/// Séance's theme: a [ThemePalette] over the sibling neutrals, built by the
/// shared [GhostTheme] from [seanceThemeStyle] — the violet accent over the
/// tables unchanged, a calm, slightly spectral look that reads well behind
/// a terminal in both light and dark.
///
/// The builder, the neutrals tables and the chrome moved to `ghost_theme`
/// (design docs/design/ghost-theme.md §5 PR 2); this is the app-side façade
/// the rest of Séance still names.
abstract final class SeanceTheme {
  /// The muted violet the accent family derives from, and the default
  /// preset's accent. Public because the server colour picker starts from
  /// it when no accent is chosen yet.
  static const Color seed = Color(0xFF6B5BD2);

  /// The Séance preset's themes, the Automatic palette at each
  /// brightness. [platform] overrides the host platform the type ramp and
  /// row extents are chosen for — tests and captures render the desktop
  /// rail and the phone home from one host.
  static ThemeData light({TargetPlatform? platform}) =>
      GhostTheme.light(seanceThemeStyle, platform: platform);
  static ThemeData dark({TargetPlatform? platform}) =>
      GhostTheme.dark(seanceThemeStyle, platform: platform);

  /// The three theme arguments of a MaterialApp drawn in [appearance].
  ///
  /// A palette with its own surface is one theme, at that surface's
  /// brightness, whatever the system or the mode says; otherwise a light
  /// and a dark one, picked between by the mode.
  static ({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
  forAppearance(AppAppearance appearance, {TargetPlatform? platform}) =>
      GhostTheme.forAppearance(
        seanceThemeStyle,
        appearance,
        platform: platform,
      );

  /// What every slot of [palette] draws as when its Automatic colours
  /// follow [brightness] — the colour an Automatic slot stands for right
  /// now, which is where the Appearance tab starts a slot that stops being
  /// Automatic, and what a preset's swatch shows.
  static Map<ThemeSlot, Color> resolvedSlots(
    ThemePalette palette,
    Brightness brightness,
  ) => GhostTheme.resolvedSlots(seanceThemeStyle, palette, brightness);

  /// [palette] as a theme. [brightness] is what its Automatic colours
  /// follow — the system's, or the mode's; a palette that sets its own
  /// surface is drawn at that surface's brightness instead (see
  /// [resolveBrightness]).
  static ThemeData build(
    ThemePalette palette,
    Brightness brightness, {
    TargetPlatform? platform,
  }) => GhostTheme.build(
    seanceThemeStyle,
    palette,
    brightness,
    platform: platform,
  );

  /// Monospace font stack for the terminal and code — the style's
  /// [GhostThemeStyle.monoFontFamilies].
  static const List<String> monoFallback = [
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ];
}

/// Colors for the online/offline/connecting/unknown indicator dots, from
/// the theme's [SeanceChrome].
///
/// The four colours live on [GhostChrome] beside the tokens they are held
/// to the same contrast floor with (Poltergeist's design), so this is an
/// adapter over the extension rather than one of its own.
class StatusColors {
  static Color online(BuildContext context) =>
      SeanceChrome.of(context, seanceThemeStyle).statusConnected;

  static Color offline(BuildContext context) =>
      SeanceChrome.of(context, seanceThemeStyle).statusFailed;

  /// A session still negotiating: amber, unless the palette says otherwise.
  static Color connecting(BuildContext context) =>
      SeanceChrome.of(context, seanceThemeStyle).statusConnecting;

  static Color unknown(BuildContext context) =>
      SeanceChrome.of(context, seanceThemeStyle).statusUnknown;
}

import 'package:ghost_theme/ghost_theme.dart';

import '../theme.dart' show SeanceTheme;

/// Séance's binding of the shared theme model: the violet seed, the brand
/// name, the Terminal preset a new device starts in, and the terminal block
/// its palettes carry.
///
/// The model — palette, presets, stored and pasted form — moved to
/// `ghost_theme` (design docs/design/ghost-theme.md §5 PR 1); this file is
/// the app-side façade the rest of Séance still names.
const GhostThemeStyle seanceThemeStyle = GhostThemeStyle(
  seed: SeanceTheme.seed,
  brand: 'Séance',
  initial: 'Terminal',
  hasTerminal: true,
);

final GhostThemePresets seanceThemePresets = GhostThemePresets(
  seanceThemeStyle,
);

/// The stored and pasted form of a Séance palette: [seanceThemeStyle]'s
/// brand completes a partial theme, its Terminal preset is the fallback a
/// settings file holding nothing usable decodes to, and the `terminal`
/// block is a palette value.
final GhostThemeCodec seanceThemeCodec = GhostThemeCodec(seanceThemeStyle);

/// The themes Séance ships with, after Vervellum's `ThemePresets.swift`,
/// bound to [seanceThemeStyle].
///
/// A preset is a starting point, not a mode: picking one copies its values
/// into the device's palette, which the user is then free to change. The
/// first, Séance, leaves everything Automatic, which is what reproduces the
/// app as it looked before themes existed. A new device starts in Terminal
/// ([initial]).
abstract final class ThemePresets {
  /// Séance's own look: its violet over the sibling neutrals, which follow
  /// the system's light or dark appearance.
  static ThemePalette get seance => seanceThemePresets.brand;

  static ThemePalette get graphite => seanceThemePresets.graphite;
  static ThemePalette get paper => seanceThemePresets.paper;
  static ThemePalette get newsprint => seanceThemePresets.newsprint;
  static ThemePalette get solarized => seanceThemePresets.solarized;
  static ThemePalette get midnight => seanceThemePresets.midnight;
  static ThemePalette get terminal => seanceThemePresets.terminal;
  static ThemePalette get vapor => seanceThemePresets.vapor;
  static ThemePalette get bubblegum => seanceThemePresets.bubblegum;
  static ThemePalette get highContrast => seanceThemePresets.highContrast;

  /// Every preset, in the order the Appearance tab shows them: the two
  /// that follow the system's light or dark (Séance first), then the light
  /// ones with surfaces of their own, then the dark ones, then the loud
  /// ones.
  static List<ThemePalette> get all => seanceThemePresets.all;

  /// What a device starts with, and what Reset puts back: green on black,
  /// for a terminal app.
  static ThemePalette get initial => seanceThemePresets.initial;
}

/// Compatibility shim for the palette identity the model used to carry:
/// `matchingPreset` and `relabelled` now need the app's preset list, so
/// they live on [seanceThemePresets]. Kept on the palette so Séance's call
/// sites and its preset test stay unchanged.
extension SeancePaletteIdentity on ThemePalette {
  /// The preset whose values these are, if any.
  ThemePalette? get matchingPreset => seanceThemePresets.matching(this);

  /// This palette named for what its values are: the matching preset's
  /// name, or [ThemePalette.customName].
  ThemePalette relabelled() => seanceThemePresets.relabel(this);
}

import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../theme.dart' show SeanceTheme;

/// Séance's dark and light neutral tables: the sibling slate/Finder
/// neutrals (shared in value with Poltergeist) with Séance's violet primary
/// family and its own per-brightness status dot colours. The error family
/// is left Automatic — `ColorScheme.fromSeed` re-seeds it with the accent.
const GhostThemeNeutrals _seanceDark = GhostThemeNeutrals(
  surface: Color(0xFF232932),
  containerLowest: Color(0xFF1C2128),
  containerLow: Color(0xFF2A313B),
  container: Color(0xFF2D3440),
  containerHigh: Color(0xFF353D49),
  containerHighest: Color(0xFF3B4452),
  onSurface: Color(0xFFE7EAEF),
  onSurfaceVariant: Color(0xFFB4BCC8),
  outline: Color(0xFF6B7584),
  outlineVariant: Color(0xFF3A424E),
  inverseSurface: Color(0xFFE7EAEF),
  onInverseSurface: Color(0xFF232932),
  primary: Color(0xFFADA1FF),
  onPrimary: Color(0xFF1D1452),
  primaryContainer: Color(0xFF43388F),
  onPrimaryContainer: Color(0xFFE6E0FF),
  secondaryContainer: Color(0xFF3B4758),
  onSecondaryContainer: Color(0xFFDCE4EF),
  selection: Color(0xFF5A4BC0),
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF3FB950),
  connecting: Color(0xFFD29922),
  failed: Color(0xFFFF7B72),
  unknown: Color(0xFF8B949E),
);

const GhostThemeNeutrals _seanceLight = GhostThemeNeutrals(
  surface: Color(0xFFFFFFFF),
  containerLowest: Color(0xFFFFFFFF),
  containerLow: Color(0xFFF1F2F4),
  container: Color(0xFFF6F6F8),
  containerHigh: Color(0xFFEBECEF),
  containerHighest: Color(0xFFE2E5EA),
  onSurface: Color(0xFF1C1F24),
  onSurfaceVariant: Color(0xFF596170),
  outline: Color(0xFF7D8591),
  outlineVariant: Color(0xFFDADDE3),
  inverseSurface: Color(0xFF2D323A),
  onInverseSurface: Color(0xFFF1F2F4),
  primary: Color(0xFF5847C2),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6E0FF),
  onPrimaryContainer: Color(0xFF1D1452),
  secondaryContainer: Color(0xFFDCE3EC),
  onSecondaryContainer: Color(0xFF18222E),
  selection: Color(0xFF5A4BC0),
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF1A7F37),
  connecting: Color(0xFFB06E00),
  failed: Color(0xFFCF222E),
  unknown: Color(0xFF57606A),
);

/// Séance's binding of the shared theme model: the violet seed, the brand
/// name, the Terminal preset a new device starts in, the terminal block its
/// palettes carry, and every component knob the shared builder diverges on
/// (design docs/design/ghost-theme.md §4).
const GhostThemeStyle seanceThemeStyle = GhostThemeStyle(
  seed: SeanceTheme.seed,
  brand: 'Séance',
  initial: 'Terminal',
  dark: _seanceDark,
  light: _seanceLight,
  hasTerminal: true,
  selectionLabel: GhostSelectionLabel.overRail,
  dialogRadius: 28,
  scalesDialogAlways: false,
  dialogTitleOnDesktop: false,
  tooltipUsesInterfaceFont: false,
  visualDensity: VisualDensity.comfortable,
  monoFontFamilies: SeanceTheme.monoFallback,
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

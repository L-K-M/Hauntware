import 'dart:ui' show Color;

import 'package:flutter/material.dart' show VisualDensity;
import 'package:ghost_theme/ghost_theme.dart';

import 'app_theme.dart' show poltergeistMonoFontFamilies, poltergeistSeedColor;

const GhostThemeNeutrals _poltergeistDark = GhostThemeNeutrals(
  surface: Color(0xFF232932),
  containerLowest: Color(0xFF1C2128),
  containerLow: Color(0xFF2A313B),
  container: Color(0xFF2D3440),
  containerHigh: Color(0xFF353D49),
  containerHighest: Color(0xFF3B4452),
  onSurface: Color(0xFFE7EAEF),
  onSurfaceVariant: Color(0xFFB4BCC8),
  outline: Color(0xFF77818F),
  outlineVariant: Color(0xFF3A424E),
  inverseSurface: Color(0xFFE7EAEF),
  onInverseSurface: Color(0xFF232932),
  primary: Color(0xFF5CC3AA),
  onPrimary: Color(0xFF00241D),
  primaryContainer: Color(0xFF1E5B4E),
  onPrimaryContainer: Color(0xFFC4F3E5),
  secondaryContainer: Color(0xFF3B4758),
  onSecondaryContainer: Color(0xFFDCE4EF),
  selection: Color(0xFF2F7F6D),
  onSelection: Color(0xFFFFFFFF),
  error: Color(0xFFFF9E94),
  errorContainer: Color(0xFF5C1F1B),
  onErrorContainer: Color(0xFFFFDAD5),
  connected: Color(0xFF4CAF50),
  connecting: Color(0xFFD99A1E),
  failed: Color(0xFFFF9E94),
  unknown: Color(0xFF77818F),
);

const GhostThemeNeutrals _poltergeistLight = GhostThemeNeutrals(
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
  primary: Color(0xFF1B7563),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFC9EDE3),
  onPrimaryContainer: Color(0xFF00382D),
  secondaryContainer: Color(0xFFDCE3EC),
  onSecondaryContainer: Color(0xFF18222E),
  selection: Color(0xFF1F7A67),
  onSelection: Color(0xFFFFFFFF),
  error: Color(0xFFB3261E),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  connected: Color(0xFF2E7D32),
  connecting: Color(0xFFA86400),
  failed: Color(0xFFB3261E),
  unknown: Color(0xFF7D8591),
);

/// Poltergeist's binding of the shared theme model (design
/// docs/design/ghost-theme.md).
const GhostThemeStyle poltergeistThemeStyle = GhostThemeStyle(
  seed: poltergeistSeedColor,
  brand: 'Poltergeist',
  initial: 'Vapor',
  dark: _poltergeistDark,
  light: _poltergeistLight,
  hasTerminal: false,
  selectionLabel: GhostSelectionLabel.overListing,
  dialogRadius: 12,
  scalesDialogAlways: true,
  dialogTitleOnDesktop: true,
  tooltipUsesInterfaceFont: true,
  fabRadius: 16,
  visualDensity: VisualDensity.compact,
  focusColorOpacity: 0.18,
  monoFontFamilies: poltergeistMonoFontFamilies,
);

final GhostThemePresets poltergeistThemePresets = GhostThemePresets(
  poltergeistThemeStyle,
);

final GhostThemeCodec poltergeistThemeCodec = GhostThemeCodec(
  poltergeistThemeStyle,
);

abstract final class ThemePresets {
  static ThemePalette get poltergeist => poltergeistThemePresets.brand;
  static ThemePalette get graphite => poltergeistThemePresets.graphite;
  static ThemePalette get paper => poltergeistThemePresets.paper;
  static ThemePalette get newsprint => poltergeistThemePresets.newsprint;
  static ThemePalette get solarized => poltergeistThemePresets.solarized;
  static ThemePalette get midnight => poltergeistThemePresets.midnight;
  static ThemePalette get terminal => poltergeistThemePresets.terminal;
  static ThemePalette get vapor => poltergeistThemePresets.vapor;
  static ThemePalette get bubblegum => poltergeistThemePresets.bubblegum;
  static ThemePalette get highContrast =>
      poltergeistThemePresets.highContrast;

  static List<ThemePalette> get all => poltergeistThemePresets.all;
  static ThemePalette get initial => poltergeistThemePresets.initial;
}

extension PoltergeistPaletteIdentity on ThemePalette {
  ThemePalette? get matchingPreset => poltergeistThemePresets.matching(this);

  ThemePalette relabelled() => poltergeistThemePresets.relabel(this);
}

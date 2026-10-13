import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart';

/// Séance's neutral tables: the sibling slate/Finder neutrals (shared in
/// value with Poltergeist) with its violet primary family and its own
/// per-brightness status dot colours. The error family is left to
/// `ColorScheme.fromSeed`.
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
/// palettes carry, and the component knobs the builder diverges on. The
/// palette suite moved here from Séance with these values, so its
/// assertions stay literal.
const GhostThemeStyle seanceStyle = GhostThemeStyle(
  seed: Color(0xFF6B5BD2),
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
  monoFontFamilies: [
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ],
);

/// Poltergeist's neutral tables: the same sibling neutrals with its teal
/// primary family, a pinned error family and its own status greens, and a
/// slightly lighter dark outline for the idle dot.
///
/// Present so the package's codec suite can bind a host without a terminal;
/// the builder's Poltergeist gate (against its frozen `legacy_theme.dart`)
/// lands with the Poltergeist switch, which owns these values.
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

/// Poltergeist's binding: its teal seed, its brand name, the Vapor preset
/// it starts in, no terminal block, and its own component knobs.
const GhostThemeStyle poltergeistStyle = GhostThemeStyle(
  seed: Color(0xFF3D8A78),
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
  monoFontFamilies: [
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ],
);

final GhostThemePresets seancePresets = GhostThemePresets(seanceStyle);
final GhostThemeCodec seanceCodec = GhostThemeCodec(seanceStyle);
final GhostThemePresets poltergeistPresets = GhostThemePresets(
  poltergeistStyle,
);
final GhostThemeCodec poltergeistCodec = GhostThemeCodec(poltergeistStyle);

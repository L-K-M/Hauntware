import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_theme/ghost_theme.dart';

/// Klabautermann's brand accent: a sea blue (HCT hue 245), apart from
/// Séance's violet, Poltergeist's teal and Planchette's burgundy.
///
/// Assumption: no plan text fixes the seed. The M1a theme drew Material's
/// baseline, whose violet is Séance's family, so the brand takes the ship
/// spirit's sea instead. The colours M1a chose itself, the four status
/// dots, carry over unchanged (see the tables below); Material's baseline
/// neutrals give way to the sibling neutrals.
const Color _seed = Color(0xFF2B6F9E);

/// The dark and light tables: the sibling slate/Finder neutrals, in value
/// the same as Séance's (ghost-theme.md §2 makes them the family contract),
/// with the sea-blue primary family and the status dots M1a's
/// `KlabautermannStatusColors` drew.
///
/// The primary family is Material's tonal-spot rendering of [_seed] (tones
/// 80/20/30/90 dark, 40/100/90/30 light). The selection pill is the seed
/// itself, which already clears 4.5:1 under white text. The error family
/// stays Automatic, as on Séance: `ColorScheme.fromSeed` supplies
/// Material's tonal error red. The theme test holds these pairs to their
/// contrast floors.
const GhostThemeNeutrals _dark = GhostThemeNeutrals(
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
  primary: Color(0xFF98CCF9),
  onPrimary: Color(0xFF003351),
  primaryContainer: Color(0xFF054B72),
  onPrimaryContainer: Color(0xFFCCE5FF),
  secondaryContainer: Color(0xFF3B4758),
  onSecondaryContainer: Color(0xFFDCE4EF),
  selection: _seed,
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF7FC98B),
  connecting: Color(0xFFD9A74A),
  failed: Color(0xFFF28B82),
  unknown: Color(0xFF9AA0A6),
);

const GhostThemeNeutrals _light = GhostThemeNeutrals(
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
  primary: Color(0xFF2B638B),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFCCE5FF),
  onPrimaryContainer: Color(0xFF054B72),
  secondaryContainer: Color(0xFFDCE3EC),
  onSecondaryContainer: Color(0xFF18222E),
  selection: _seed,
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF2F7A3A),
  connecting: Color(0xFF915C00),
  failed: Color(0xFFB3261E),
  unknown: Color(0xFF6E665A),
);

/// The brand preset's stored name; stored and pasted theme names stay
/// English across the family.
const String _brand = 'Klabautermann';

/// Klabautermann's binding of the shared theme builder (03 D9, §10.9;
/// ghost-theme.md §4 and §5 "Klabautermann (M1+)").
///
/// - A new device starts in the brand preset (an assumption, like the
///   seed): it leaves every colour Automatic, so it follows the system's
///   light or dark as the M1a theme did, and it is the kind of preset the
///   Appearance tab's theme-mode switch acts on (a preset with a surface
///   of its own is drawn at that surface's brightness whatever the mode).
/// - No terminal block: the app has no themed terminal, so its presets
///   carry none and a later codec reads past a pasted `terminal` key.
/// - The selection label is chosen over the rail, where the fleet's
///   selection pill sits, as on Séance's server rail.
/// - Material's own dialog shape and tooltip text (Séance's knobs), as the
///   M1a theme drew them; the app has no floating button to theme. The
///   tooltip names no interface font because there is no font setting
///   yet; theme editing revisits that knob.
/// - Compact density: what M1a's default theme already resolved to on the
///   desktop platforms the three-pane fleet view is built for.
/// - The siblings' monospace stack, for the log and command output later
///   milestones draw.
const GhostThemeStyle klabautermannThemeStyle = GhostThemeStyle(
  seed: _seed,
  brand: _brand,
  initial: _brand,
  dark: _dark,
  light: _light,
  hasTerminal: false,
  selectionLabel: GhostSelectionLabel.overRail,
  dialogRadius: 28,
  scalesDialogAlways: false,
  dialogTitleOnDesktop: false,
  tooltipUsesInterfaceFont: false,
  visualDensity: VisualDensity.compact,
  monoFontFamilies: ghostMonoFontFamilies,
);

/// The brand preset followed by the nine looks the family shares, bound to
/// [klabautermannThemeStyle].
final GhostThemePresets klabautermannThemePresets = GhostThemePresets(
  klabautermannThemeStyle,
);

/// The app's monospace face: its stack, `ghost_fonts`' bundled family
/// first, which every platform draws; the generic family alone resolves on
/// Linux and Android only.
final TextStyle klabautermannMonoStyle = TextStyle(
  fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
  fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
      .skip(1)
      .toList(growable: false),
);

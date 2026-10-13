import 'dart:ui' show Color;

import 'package:flutter/material.dart' show VisualDensity;

import 'ghost_theme_neutrals.dart';

/// Which surface a derived selection label (`onSelection`) is chosen
/// against: the rail it sits on, or the listing it paints over.
///
/// The two apps composite over different backgrounds — Séance's label is
/// chosen against the rail, Poltergeist's against the listing — which is
/// why the shared builder cannot pick one.
enum GhostSelectionLabel {
  /// Composite the selection pill over the rail (`containerLow`).
  overRail,

  /// Composite it over the listing (`surface`).
  overListing,
}

/// The fixed inputs a host binds the shared theme builder to: who the brand
/// preset is, which preset a device starts in, whether its palettes carry a
/// terminal block, and every component-level divergence between the apps.
///
/// This is the style half of the extraction (design
/// docs/design/ghost-theme.md §4). Every divergence is a required parameter,
/// so a host that misses one fails to compile instead of drawing another
/// app's theme; the null-defaulted hooks mean "absent", not an app's choice.
final class GhostThemeStyle {
  const GhostThemeStyle({
    required this.seed,
    required this.brand,
    required this.initial,
    required this.dark,
    required this.light,
    required this.hasTerminal,
    required this.selectionLabel,
    required this.dialogRadius,
    required this.scalesDialogAlways,
    required this.dialogTitleOnDesktop,
    required this.tooltipUsesInterfaceFont,
    this.fabRadius,
    required this.visualDensity,
    this.focusColorOpacity,
    required this.monoFontFamilies,
  });

  /// The accent the brand preset — and the tuned neutral tables — is built
  /// around. A palette whose accent equals it keeps the table's hand-tuned
  /// primary family; any other accent is drawn as picked.
  final Color seed;

  /// The first preset's stored name: 'Séance', 'Poltergeist', ... Stored
  /// and pasted theme names stay English across the apps.
  final String brand;

  /// The `name` of the preset in [GhostThemePresets.all] a device starts
  /// in — what a settings file holding nothing usable decodes to.
  final String initial;

  /// The dark and light neutral tables (see [GhostThemeNeutrals]).
  final GhostThemeNeutrals dark;
  final GhostThemeNeutrals light;

  /// Whether this app's palettes carry a `ThemeTerminalColors` block.
  /// Séance's do; an app without a themed terminal sets false and its
  /// presets and codec then read past a pasted `terminal` key and never
  /// write one — exactly what cross-app paste needs.
  final bool hasTerminal;

  /// Which surface a derived selection label is chosen against.
  final GhostSelectionLabel selectionLabel;

  /// The dialog's corner radius at the designed scale. Séance's 28; smaller
  /// where Material's 24 px desktop headline would dominate the panel
  /// (Poltergeist's 12).
  final double dialogRadius;

  /// Whether the dialog is shaped at every scale. Séance shapes it only
  /// when the corner scale is not 1 (at 1 it keeps Material's own shape);
  /// Poltergeist always shapes it.
  final bool scalesDialogAlways;

  /// Whether the dialog title follows the desktop ramp (13 px family at
  /// 17 px semibold), rather than Material's oversized headline.
  final bool dialogTitleOnDesktop;

  /// Whether the tooltip text style names the interface font. A tooltip's
  /// style replaces the text theme's rather than merging with it, so a host
  /// with a font picker names the font here too.
  final bool tooltipUsesInterfaceFont;

  /// The floating action button's corner radius at the designed scale, or
  /// null for a host with no floating button theme.
  final double? fabRadius;

  /// The host's row density (Séance comfortable, Poltergeist compact).
  final VisualDensity visualDensity;

  /// The alpha of the focus colour over the scheme's primary, or null for a
  /// host that leaves Material's default.
  final double? focusColorOpacity;

  /// The monospace family stack for the terminal and code, primary first,
  /// then cross-platform fallbacks.
  final List<String> monoFontFamilies;
}

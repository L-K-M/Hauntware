import 'dart:ui' show Color;

/// The fixed inputs a host binds the shared theme model to: who the brand
/// preset is, which preset a device starts in, and whether its palettes
/// carry a terminal block.
///
/// This is the model half of the style the shared builder will take; the
/// neutrals tables and component knobs join it when the builder moves
/// (design docs/design/ghost-theme.md §4).
final class GhostThemeStyle {
  const GhostThemeStyle({
    required this.seed,
    required this.brand,
    required this.initial,
    this.hasTerminal = false,
  });

  /// The accent the brand preset — and, once the builder lands, the
  /// tuned neutral tables — is built around.
  final Color seed;

  /// The first preset's stored name: 'Séance', 'Poltergeist', ... Stored
  /// and pasted theme names stay English across the apps.
  final String brand;

  /// The `name` of the preset in `GhostThemePresets.all` a device starts
  /// in — what a settings file holding nothing usable decodes to.
  final String initial;

  /// Whether this app's palettes carry a `ThemeTerminalColors` block.
  /// Séance's do; an app without a themed terminal sets false and its
  /// presets and codec then read past a pasted `terminal` key and never
  /// write one — exactly what cross-app paste needs.
  final bool hasTerminal;
}

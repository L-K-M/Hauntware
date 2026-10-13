import 'dart:ui' show Color;

/// One brightness of a host's neutral table: the fixed colours the shared
/// builder mixes a palette's Automatic slots from.
///
/// The neutral fields themselves — the surface, the container ladder, the
/// text and the outlines — carry the same values in every host (the sibling
/// look, slate dark and Finder light, is the contract, not a coincidence).
/// The per-app surface is the primary family, the error family and the four
/// status fallbacks: Séance's violet and its own status dots, Poltergeist's
/// teal and pinned error. A table is required by [GhostThemeStyle], so a
/// host that forgets one fails to compile rather than drawing a sibling's
/// colours.
final class GhostThemeNeutrals {
  const GhostThemeNeutrals({
    required this.surface,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.containerHighest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.selection,
    required this.onSelection,
    this.error,
    this.errorContainer,
    this.onErrorContainer,
    required this.connected,
    required this.connecting,
    required this.failed,
    required this.unknown,
  });

  final Color surface;
  final Color containerLowest;
  final Color containerLow;
  final Color container;
  final Color containerHigh;
  final Color containerHighest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color selection;

  /// The label for the table's own (tuned) accent when a palette brings no
  /// selection of its own. Séance's equals the label the builder would
  /// derive over the rail; Poltergeist pins its hand-tuned white. Any other
  /// selection derives its label (see [GhostChrome.onSelection]).
  final Color onSelection;

  /// The error family: text colours with a contrast floor of their own.
  /// Null leaves them to `ColorScheme.fromSeed` (Séance); set pins them
  /// against a custom accent (Poltergeist).
  final Color? error;
  final Color? errorContainer;
  final Color? onErrorContainer;

  /// The status dots' Automatic fallbacks: the connected green, the
  /// connecting amber, the failure red, and the unknown grey. Séance's are
  /// its own per-brightness constants; Poltergeist's mirror its [error] and
  /// [outline], so a palette's red dot cannot restyle the error text.
  final Color connected;
  final Color connecting;
  final Color failed;
  final Color unknown;
}

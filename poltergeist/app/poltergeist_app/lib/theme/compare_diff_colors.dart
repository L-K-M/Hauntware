import 'package:flutter/material.dart';

import 'contrast.dart';
import 'family_hues.dart';

/// The compare view's diff colours (06 §6): the editor-theme-style slots
/// D20 asks for, derived from each palette's own surface so every preset
/// keeps them legible. The shared `EditorSyntaxTheme` stays unchanged;
/// diff rows carry no syntax colours, so nothing else lands on a tint.
@immutable
final class CompareDiffColors extends ThemeExtension<CompareDiffColors> {
  const CompareDiffColors({
    required this.addedFill,
    required this.removedFill,
    required this.addedText,
    required this.removedText,
    required this.addedMarker,
    required this.removedMarker,
    required this.gapFill,
    required this.activeRegion,
  });

  /// The family green and red as washes over [surface]. The wash strength
  /// is fixed so the tints stay visible on every palette; it is the text
  /// and marker colours that move, and only as far as the 4.5:1 text and
  /// 3:1 marker floors need.
  factory CompareDiffColors.derive({
    required Brightness brightness,
    required Color surface,
    required Color onSurface,
    required Color accent,
  }) {
    final hues = FamilyPalette.forBrightness(brightness);
    final added = hues.glyph(FamilyHue.green);
    final removed = hues.glyph(FamilyHue.red);
    final alpha = brightness == Brightness.dark
        ? _darkWashAlpha
        : _lightWashAlpha;
    final addedFill = compositeOver(added.withValues(alpha: alpha), surface);
    final removedFill = compositeOver(
      removed.withValues(alpha: alpha),
      surface,
    );
    return CompareDiffColors(
      addedFill: addedFill,
      removedFill: removedFill,
      addedText: _legible(onSurface, [addedFill], _textContrast),
      removedText: _legible(onSurface, [removedFill], _textContrast),
      addedMarker: _legible(added, [addedFill], _markContrast),
      removedMarker: _legible(removed, [removedFill], _markContrast),
      gapFill: compositeOver(onSurface.withValues(alpha: _gapAlpha), surface),
      activeRegion: _legible(accent, [
        surface,
        addedFill,
        removedFill,
      ], _markContrast),
    );
  }

  /// A removed line's row, and its text and −/+ marker on it.
  final Color removedFill;
  final Color removedText;
  final Color removedMarker;

  /// An added line's row, and its text and marker on it.
  final Color addedFill;
  final Color addedText;
  final Color addedMarker;

  /// The empty half facing a line the other side lacks.
  final Color gapFill;

  /// The bar beside the rows of the region n / Shift+N last moved to.
  final Color activeRegion;

  /// The colours for [context]'s theme, derived from its scheme when a
  /// host theme (a test harness, a dialog subtree) carries none.
  static CompareDiffColors of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return theme.extension<CompareDiffColors>() ??
        CompareDiffColors.derive(
          brightness: theme.brightness,
          surface: scheme.surface,
          onSurface: scheme.onSurface,
          accent: scheme.primary,
        );
  }

  @override
  CompareDiffColors copyWith({
    Color? addedFill,
    Color? removedFill,
    Color? addedText,
    Color? removedText,
    Color? addedMarker,
    Color? removedMarker,
    Color? gapFill,
    Color? activeRegion,
  }) => CompareDiffColors(
    addedFill: addedFill ?? this.addedFill,
    removedFill: removedFill ?? this.removedFill,
    addedText: addedText ?? this.addedText,
    removedText: removedText ?? this.removedText,
    addedMarker: addedMarker ?? this.addedMarker,
    removedMarker: removedMarker ?? this.removedMarker,
    gapFill: gapFill ?? this.gapFill,
    activeRegion: activeRegion ?? this.activeRegion,
  );

  @override
  CompareDiffColors lerp(CompareDiffColors? other, double t) {
    if (other == null) return this;
    return CompareDiffColors(
      addedFill: Color.lerp(addedFill, other.addedFill, t)!,
      removedFill: Color.lerp(removedFill, other.removedFill, t)!,
      addedText: Color.lerp(addedText, other.addedText, t)!,
      removedText: Color.lerp(removedText, other.removedText, t)!,
      addedMarker: Color.lerp(addedMarker, other.addedMarker, t)!,
      removedMarker: Color.lerp(removedMarker, other.removedMarker, t)!,
      gapFill: Color.lerp(gapFill, other.gapFill, t)!,
      activeRegion: Color.lerp(activeRegion, other.activeRegion, t)!,
    );
  }

  // Value equality, so a rebuilt theme with the same colours does not
  // restart the theme animation.
  @override
  bool operator ==(Object other) =>
      other is CompareDiffColors &&
      other.addedFill == addedFill &&
      other.removedFill == removedFill &&
      other.addedText == addedText &&
      other.removedText == removedText &&
      other.addedMarker == addedMarker &&
      other.removedMarker == removedMarker &&
      other.gapFill == gapFill &&
      other.activeRegion == activeRegion;

  @override
  int get hashCode => Object.hash(
    addedFill,
    removedFill,
    addedText,
    removedText,
    addedMarker,
    removedMarker,
    gapFill,
    activeRegion,
  );

  /// [color] as is when it clears [floor] against every background, else
  /// the first step towards black or white that does.
  static Color _legible(Color color, List<Color> backgrounds, double floor) {
    final target = legibleOn(backgrounds.first);
    for (var step = 0; step <= _legibleSteps; step++) {
      final candidate = Color.lerp(color, target, step / _legibleSteps)!;
      if (backgrounds.every((bg) => contrastRatio(candidate, bg) >= floor)) {
        return candidate;
      }
    }
    return target;
  }
}

const double _darkWashAlpha = 0.16;
const double _lightWashAlpha = 0.12;
const double _gapAlpha = 0.05;
const double _textContrast = 4.5;
const double _markContrast = 3.0;
const int _legibleSteps = 10;

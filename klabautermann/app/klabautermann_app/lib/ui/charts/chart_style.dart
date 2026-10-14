import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show FamilyHue, FamilyPalette;

/// The warning and critical levels of a metric where higher is worse (CPU,
/// memory, disk, rates): a value at or above a level has that severity.
@immutable
final class ChartThresholds {
  const ChartThresholds({required this.warning, required this.critical})
    : assert(warning <= critical, 'warning must not exceed critical');

  final double warning;
  final double critical;
}

/// The colours a chart draws with (03 §10.7, A11Y-04): series and severity
/// tints from the family palette, text from the colour scheme.
///
/// The family tints already hold 3:1 on every chrome surface, and the chart
/// palette test holds this selection to that floor on the chart surfaces
/// and keeps each set apart under simulated colour-vision deficiencies.
@immutable
final class ChartPalette {
  const ChartPalette({
    required this.series,
    required this.warning,
    required this.critical,
    required this.scaleText,
  });

  /// The palette for [context]'s theme.
  factory ChartPalette.of(BuildContext context) =>
      ChartPalette.fromTheme(Theme.of(context));

  /// The palette for [theme], with the family tints it carries or, like
  /// [FamilyPalette.of], its brightness's defaults.
  factory ChartPalette.fromTheme(ThemeData theme) {
    final family =
        theme.extension<FamilyPalette>() ??
        FamilyPalette.forBrightness(theme.brightness);
    return ChartPalette(
      series: [for (final hue in _seriesHues) family.glyph(hue)],
      warning: family.glyph(FamilyHue.yellow),
      critical: theme.brightness == Brightness.dark
          ? family.glyph(FamilyHue.red)
          : _lightCritical,
      scaleText: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// Blue and orange first, the pair every common colour-vision deficiency
  /// keeps apart, then teal and brown: of the family's hues, the four whose
  /// worst pair stays furthest apart under simulated protanopia,
  /// deuteranopia and tritanopia in both themes. Yellow and red stay out,
  /// because they mean warning and critical here.
  static const _seriesHues = [
    FamilyHue.blue,
    FamilyHue.orange,
    FamilyHue.teal,
    FamilyHue.brown,
  ];

  /// The family's light red sits too close to its amber in lightness to
  /// part from it under deuteranopia; this deeper red keeps them apart.
  static const _lightCritical = Color(0xFFA31515);

  /// Up to four series, in the order a chart assigns them.
  final List<Color> series;

  /// The bands past a warning and a critical threshold.
  final Color warning;
  final Color critical;

  /// The scale label a sparkline shows.
  final Color scaleText;
}

/// Whether the platform asks for no motion (A11Y-11): Android's "Remove
/// animations" arrives through [MediaQuery], iOS's Reduce Motion only
/// through the platform's accessibility features. Charts read it when an
/// update would start an animation, so a change takes effect on the next
/// sample.
bool chartMotionReduced(BuildContext context) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return true;
  final view = View.maybeOf(context);
  return view?.platformDispatcher.accessibilityFeatures.reduceMotion ?? false;
}

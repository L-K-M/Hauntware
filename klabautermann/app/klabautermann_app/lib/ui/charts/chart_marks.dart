import 'package:flutter/material.dart';

import 'chart_style.dart';
import 'chart_values.dart';

// What the bars, the gauge and the core heatmap share: which values they
// can draw, how a severity reads in words, and the icon that shows it by
// shape (A11Y-01). Kept out of the charts' barrel.

/// A value a chart can draw: null, negative or not finite is no reading,
/// shown as unknown rather than as zero (03 §10.4).
double? chartReading(double? value) =>
    value != null && value.isFinite && value >= 0 ? value : null;

/// [part] with [severity]'s words, or as it is below every level.
String withSeverityWords(
  String part,
  ChartSeverity severity,
  ChartStrings strings,
) => switch (severity) {
  ChartSeverity.normal => part,
  ChartSeverity.careful => strings.withSeverity(part, strings.severityCareful),
  ChartSeverity.warning => strings.withSeverity(part, strings.severityWarning),
  ChartSeverity.critical => strings.withSeverity(
    part,
    strings.severityCritical,
  ),
};

/// The side of [severitySlot]'s icon.
const severityIconSize = 14.0;

/// The icon beside a bar that shows its severity by shape as well as
/// colour (A11Y-01): a triangle for warning, a circle for critical. The
/// slot keeps its size when empty, so the bar never changes length.
Widget severitySlot(ChartSeverity severity, ChartPalette palette) =>
    SizedBox.square(
      dimension: severityIconSize,
      child: switch (severity) {
        ChartSeverity.normal => null,
        ChartSeverity.careful => Icon(
          Icons.info_rounded,
          size: severityIconSize,
          color: palette.scaleText,
        ),
        ChartSeverity.warning => Icon(
          Icons.warning_rounded,
          size: severityIconSize,
          color: palette.warning,
        ),
        ChartSeverity.critical => Icon(
          Icons.error_rounded,
          size: severityIconSize,
          color: palette.critical,
        ),
      },
    );

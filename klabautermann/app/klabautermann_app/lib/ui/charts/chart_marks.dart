import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_style.dart';
import 'chart_values.dart';

// What the charts share: which values they can draw, how a severity reads
// in words, the icon that shows it by shape (A11Y-01), the threshold bands
// and the shape that tells one series from another without colour
// (03 §10.10). Kept out of the charts' barrel.

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

/// A threshold band: the value it starts at and its colour.
typedef ThresholdBand = ({double from, Color color});

/// A band's wash over the plot, light enough to keep a line legible. The
/// wash is decoration: the rule at its threshold carries the band's colour
/// at the strength the palette test checks.
const thresholdBandAlpha = 0.16;

const _thresholdRuleWidth = 1.0;

/// Paints [critical] and [warning] across [area] as the sparkline and the
/// time-series chart draw them: a wash from each level up to the next band
/// or the top, and a rule at the level. A level at or above [scaleMax], or
/// one that is not finite, draws nothing.
void paintThresholdBands(
  Canvas canvas,
  Rect area, {
  required double Function(double value) yOf,
  required double scaleMax,
  required ThresholdBand? warning,
  required ThresholdBand? critical,
}) {
  var bandTop = area.top;
  for (final band in [critical, warning]) {
    if (band == null || !band.from.isFinite || band.from >= scaleMax) continue;
    final bottom = yOf(band.from);
    if (bottom <= bandTop) continue;
    canvas.drawRect(
      Rect.fromLTRB(area.left, bandTop, area.right, bottom),
      Paint()..color = band.color.withValues(alpha: thresholdBandAlpha),
    );
    canvas.drawRect(
      Rect.fromLTRB(
        area.left,
        bottom - _thresholdRuleWidth,
        area.right,
        bottom,
      ),
      Paint()..color = band.color,
    );
    bandTop = bottom;
  }
}

/// The shape that marks a series beside its name and on its line, so a
/// legend entry matches its line without colour (03 §10.10). A dash pattern
/// would read as missed samples, so the lines stay solid.
enum ChartMarker {
  circle,
  square,
  triangle,
  diamond;

  /// The marker of a chart's [lane]th series.
  static ChartMarker forLane(int lane) => values[lane % values.length];
}

/// The width and height of a [ChartMarker].
const chartMarkerSize = 8.0;

/// The ring of the surface colour around a marker on a plot, so it stands
/// clear of the lines it sits on.
const chartMarkerHalo = 1.5;

/// Paints [marker] centred on [center] in [color], with a [halo] ring of
/// the surface colour around it when given.
void paintChartMarker(
  Canvas canvas,
  ChartMarker marker,
  Offset center,
  Color color, {
  Color? halo,
}) {
  final path = chartMarkerPath(marker, center);
  if (halo != null) {
    canvas.drawPath(
      path,
      Paint()
        ..color = halo
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * chartMarkerHalo
        ..strokeJoin = StrokeJoin.round,
    );
  }
  canvas.drawPath(path, Paint()..color = color);
}

/// [marker]'s outline centred on [center], each shape of about the same
/// area as the circle, so none reads as larger.
Path chartMarkerPath(ChartMarker marker, Offset center) {
  const half = chartMarkerSize / 2;
  return switch (marker) {
    ChartMarker.circle =>
      Path()..addOval(Rect.fromCircle(center: center, radius: half)),
    ChartMarker.square =>
      Path()..addRect(
        Rect.fromCenter(center: center, width: half * 1.8, height: half * 1.8),
      ),
    ChartMarker.triangle =>
      Path()..addPolygon([
        center + const Offset(0, -half * 1.15),
        center + Offset(half * 1.15 * math.cos(math.pi / 6), half * 0.85),
        center + Offset(-half * 1.15 * math.cos(math.pi / 6), half * 0.85),
      ], true),
    ChartMarker.diamond =>
      Path()..addPolygon([
        center + const Offset(0, -half * 1.2),
        center + const Offset(half * 1.2, 0),
        center + const Offset(0, half * 1.2),
        center + const Offset(-half * 1.2, 0),
      ], true),
  };
}

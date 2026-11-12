import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'bars.dart' show BarFill;
import 'chart_marks.dart';
import 'chart_style.dart';
import 'chart_values.dart';

/// A radial gauge (03 §10.7, OV-03): [value]'s share of [total] on a
/// three-quarter arc, with the share in its middle.
///
/// It reads as a [StackedBar] of one segment does: past a level of
/// [thresholds] the fill takes the severity colour with a stripe of the
/// track along it, an icon under the share shows the severity by its shape,
/// and the summary says it (A11Y-01); ticks outside the arc mark where the
/// warning and critical levels start. An unknown value or total hatches
/// the arc rather than drawing it empty (03 §10.4), and [stale] values turn
/// the fill grey and carry no severity (OV-04).
///
/// Screen readers get one summary in the stacked bar's words (A11Y-02),
/// which is not a live region (A11Y-15). The gauge does not animate, so
/// reduced motion (A11Y-11) changes nothing.
class Gauge extends StatelessWidget {
  const Gauge({
    super.key,
    required this.label,
    required this.part,
    required this.value,
    required this.total,
    required this.unit,
    required this.strings,
    this.thresholds,
    this.stale = false,
    this.diameter = 72,
  });

  /// What the gauge measures, as its summary names it ("Memory").
  final String label;

  /// What [value] is, as the summary names it ("Used").
  final String part;

  /// The measured value in [unit]; null when the host did not report it.
  final double? value;

  /// What a full arc stands for, in [unit]; null when unknown.
  final double? total;

  final ChartUnit unit;
  final ChartStrings strings;

  /// The levels, in percent of [total].
  final ChartThresholds? thresholds;

  /// Whether the values are the last ones before sampling fell behind.
  final bool stale;

  /// The arc's outer size, ticks included, before text scaling.
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final value = chartReading(this.value);
    final total = chartReading(this.total);
    final share = value != null && total != null && total > 0
        ? math.min(1.0, value / total)
        : null;
    final thresholds = this.thresholds;
    final severity = stale || thresholds == null || share == null
        ? ChartSeverity.normal
        : thresholds.severityOf(share * 100);

    String format(double? figure) => figure == null
        ? strings.unknownValue
        : formatChartValue(figure, unit, strings);
    final legend = withSeverityWords(
      strings.barPart(part, format(value)),
      severity,
      strings,
    );
    var summary = value == null && total == null
        ? strings.seriesUnknown(label)
        : strings.barSummary(label, legend, format(total));
    if (stale) summary = strings.stale(summary);

    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final size = scaler.scale(diameter);
    final arc = SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: GaugePainter(
                  share: share,
                  color: stale
                      ? palette.muted
                      : palette.severityColor(severity) ?? palette.series.first,
                  fill: severity.alarms ? BarFill.severe : BarFill.solid,
                  trackColor: palette.track,
                  unknownColor: palette.muted,
                  ticks: [
                    if (thresholds != null) ...[
                      (at: thresholds.warning / 100, color: palette.warning),
                      (at: thresholds.critical / 100, color: palette.critical),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Inside the arc, scaled down when a word such as "unknown" or
          // large text would not fit between its sides.
          Padding(
            padding: EdgeInsets.all(
              (GaugePainter.strokeWidth + GaugePainter.tickLength + 4) *
                  size /
                  diameter,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    share == null
                        ? strings.unknownValue
                        : strings.percent(share * 100),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: stale ? palette.scaleText : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                  ),
                  if (thresholds != null) severitySlot(severity, palette),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            arc,
            // The value in words under the arc, with its severity: the only
            // place the severity shows in words (A11Y-01).
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: scaler.scale(legendWidth)),
              child: Text(
                legend,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: palette.scaleText,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// How wide the words under the arc may grow before they wrap, before
  /// text scaling.
  static const legendWidth = 128.0;
}

/// Where a threshold starts on a [Gauge]'s arc, as a share of the arc, and
/// its colour.
typedef GaugeTick = ({double at, Color color});

/// Paints a [Gauge]'s arc; visible so painter tests can check what it
/// draws, and kept out of the charts' barrel. It takes values rather than
/// a ring, so it repaints when they change.
@visibleForTesting
final class GaugePainter extends CustomPainter {
  GaugePainter({
    required this.share,
    required this.color,
    required this.fill,
    required this.trackColor,
    required this.unknownColor,
    required this.ticks,
  });

  /// The filled share of the arc from 0 to 1, or null to hatch it.
  final double? share;
  final Color color;

  /// [BarFill.severe] draws a stripe of the track along the fill; the
  /// unknown fill comes from a null [share].
  final BarFill fill;
  final Color trackColor;
  final Color unknownColor;
  final List<GaugeTick> ticks;

  /// The arc starts at the lower left and sweeps three quarters of a turn
  /// clockwise, leaving the bottom open for the severity icon.
  static const startAngle = math.pi * 3 / 4;
  static const sweepAngle = math.pi * 3 / 2;

  static const strokeWidth = 8.0;
  static const tickLength = 4.0;
  static const tickWidth = 2.0;

  /// The stripe along a severe fill, as wide as a bar's.
  static const severeStripe = 2.0;

  /// The angle between the hatch marks of an unknown arc.
  static const _hatchStep = math.pi / 24;

  @override
  void paint(Canvas canvas, Size size) {
    final radius =
        math.min(size.width, size.height) / 2 - tickLength - strokeWidth / 2;
    if (radius <= 0) return;
    final center = size.center(Offset.zero);
    final arcRect = Rect.fromCircle(center: center, radius: radius);
    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    canvas.drawArc(
      arcRect,
      startAngle,
      sweepAngle,
      false,
      stroke(trackColor, strokeWidth),
    );

    final share = this.share;
    if (share == null) {
      // Marks across the track, the gauge's hatching: unknown reads by
      // pattern, not by an empty arc that would say zero.
      final marks = stroke(unknownColor, 1);
      for (
        var angle = startAngle;
        angle <= startAngle + sweepAngle;
        angle += _hatchStep
      ) {
        final direction = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          center + direction * (radius - strokeWidth / 2),
          center + direction * (radius + strokeWidth / 2),
          marks,
        );
      }
    } else if (share > 0) {
      final sweep = sweepAngle * share.clamp(0.0, 1.0);
      canvas.drawArc(
        arcRect,
        startAngle,
        sweep,
        false,
        stroke(color, strokeWidth),
      );
      if (fill == BarFill.severe) {
        canvas.drawArc(
          arcRect,
          startAngle,
          sweep,
          false,
          stroke(trackColor, severeStripe),
        );
      }
    }

    for (final tick in ticks) {
      final angle = startAngle + sweepAngle * tick.at.clamp(0.0, 1.0);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final outer = radius + strokeWidth / 2;
      canvas.drawLine(
        center + direction * outer,
        center + direction * (outer + tickLength),
        stroke(tick.color, tickWidth),
      );
    }
  }

  @override
  bool shouldRepaint(GaugePainter oldDelegate) =>
      oldDelegate.share != share ||
      oldDelegate.color != color ||
      oldDelegate.fill != fill ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.unknownColor != unknownColor ||
      !listEquals(oldDelegate.ticks, ticks);
}

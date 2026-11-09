import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_marks.dart';
import 'chart_style.dart';
import 'chart_values.dart';

/// Many cores at a glance (03 §10.7, CPU-02): one small cell per core in
/// the order given, each filled from the bottom to its busy share, so a
/// 64-core host fits a phone's width where a bar per core would not.
///
/// The fill's height carries the value, not its colour, which stays the
/// series colour (A11Y-01); a core the host did not report is hatched,
/// never empty (03 §10.4), and [stale] values turn every fill grey
/// (OV-04). Hovering or long-pressing a cell names the core and its share.
/// Screen readers get one summary instead (A11Y-02): how many cores, their
/// average and the busiest, which is not a live region (A11Y-15). The
/// heatmap does not animate, so reduced motion (A11Y-11) changes nothing.
class CoreHeatmap extends StatelessWidget {
  const CoreHeatmap({
    super.key,
    required this.label,
    required this.cores,
    required this.strings,
    this.stale = false,
  });

  /// What the heatmap shows, as its summary names it.
  final String label;

  /// Each core's name and busy share from 0 to 100, null when unknown.
  final List<(String, double?)> cores;

  final ChartStrings strings;

  /// Whether the values are the last ones before sampling fell behind.
  final bool stale;

  /// A cell's side before text scaling: as tall as a fleet row's bar is
  /// long would crowd, so a square a fingertip's tooltip can find.
  static const cellSize = 14.0;
  static const cellGap = 2.0;

  @override
  Widget build(BuildContext context) {
    assert(cores.isNotEmpty, 'a heatmap needs a core');
    final palette = ChartPalette.of(context);
    final shares = [for (final (_, value) in cores) chartReading(value)];

    String percent(double? value) =>
        value == null ? strings.unknownValue : strings.percent(value);
    final known = [
      for (final (index, share) in shares.indexed)
        if (share != null) (cores[index].$1, share),
    ];
    var summary = known.isEmpty
        ? strings.seriesUnknown(label)
        : strings.heatmapSummary(
            label,
            cores.length,
            percent(
              known.fold(0.0, (sum, core) => sum + core.$2) / known.length,
            ),
            () {
              final busiest = known.reduce((a, b) => b.$2 > a.$2 ? b : a);
              return strings.barPart(busiest.$1, percent(busiest.$2));
            }(),
          );
    if (stale) summary = strings.stale(summary);

    final side = MediaQuery.textScalerOf(context).scale(cellSize);
    return Semantics(
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: Wrap(
          spacing: cellGap,
          runSpacing: cellGap,
          children: [
            for (final (index, (name, _)) in cores.indexed)
              Tooltip(
                message: strings.barPart(name, percent(shares[index])),
                excludeFromSemantics: true,
                child: SizedBox.square(
                  dimension: side,
                  child: CustomPaint(
                    painter: CoreCellPainter(
                      share: shares[index] == null
                          ? null
                          : math.min(1.0, shares[index]! / 100),
                      color: stale ? palette.muted : palette.series.first,
                      trackColor: palette.track,
                      unknownColor: palette.muted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paints one [CoreHeatmap] cell: the track, then the fill from the
/// bottom to [share], or hatching when [share] is null. Visible so painter
/// tests can check what it draws, and kept out of the charts' barrel.
@visibleForTesting
final class CoreCellPainter extends CustomPainter {
  CoreCellPainter({
    required this.share,
    required this.color,
    required this.trackColor,
    required this.unknownColor,
  });

  final double? share;
  final Color color;
  final Color trackColor;
  final Color unknownColor;

  static const _cornerRadius = 2.0;
  static const _hatchSpacing = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (rect.isEmpty) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_cornerRadius)),
    );
    canvas.drawRect(rect, Paint()..color = trackColor);

    final share = this.share;
    if (share == null) {
      final lines = Path();
      for (var x = -size.height; x < size.width; x += _hatchSpacing) {
        lines
          ..moveTo(x, size.height)
          ..lineTo(x + size.height, 0);
      }
      canvas.drawPath(
        lines,
        Paint()
          ..color = unknownColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    } else if (share > 0) {
      canvas.drawRect(
        Rect.fromLTRB(0, size.height * (1 - share), size.width, size.height),
        Paint()..color = color,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CoreCellPainter oldDelegate) =>
      oldDelegate.share != share ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.unknownColor != unknownColor;
}

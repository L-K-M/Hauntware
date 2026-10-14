import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_style.dart';
import 'chart_values.dart';
import 'series_ring.dart';

/// A session sparkline (03 §10.7, OV-03): one [SeriesRing] drawn newest at
/// the right edge on a scale from zero, with threshold bands behind the
/// line and gaps where samples are unknown.
///
/// A new sample rebuilds only this widget, which hands the painter the
/// ring's new version; the painter repaints on a version change, inside
/// its own [RepaintBoundary]. The line slides in by one slot unless the
/// platform asks for reduced motion (A11Y-11). Screen readers get the
/// series summary (A11Y-02), which is not a live region (A11Y-15).
class Sparkline extends StatefulWidget {
  const Sparkline({
    super.key,
    required this.series,
    required this.label,
    required this.unit,
    required this.strings,
    this.max,
    this.thresholds,
    this.color,
    this.showScale = false,
  });

  final SeriesRing series;

  /// What the series measures, as its summary names it.
  final String label;

  final ChartUnit unit;
  final ChartStrings strings;

  /// The top of the scale; null scales to the data ([chartScaleMax]).
  final double? max;

  /// Draws warning and critical bands behind the line.
  final ChartThresholds? thresholds;

  /// The line's colour; null takes the palette's first series colour.
  final Color? color;

  /// Shows the scale's top value above the plot: the sparkline's axis.
  final bool showScale;

  @override
  State<Sparkline> createState() => _SparklineState();
}

class _SparklineState extends State<Sparkline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 1,
  );
  late int _added;

  /// Read in [build], so a sample's listener needs no context lookup.
  bool _motionReduced = false;

  @override
  void initState() {
    super.initState();
    _added = widget.series.added;
    widget.series.addListener(_onSeriesChanged);
  }

  @override
  void didUpdateWidget(Sparkline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series == widget.series) return;
    oldWidget.series.removeListener(_onSeriesChanged);
    widget.series.addListener(_onSeriesChanged);
    _added = widget.series.added;
    _slide.value = 1;
  }

  @override
  void dispose() {
    widget.series.removeListener(_onSeriesChanged);
    _slide.dispose();
    super.dispose();
  }

  void _onSeriesChanged() {
    final steppedByOne = widget.series.added == _added + 1;
    _added = widget.series.added;
    setState(() {});
    if (!steppedByOne || _motionReduced) {
      _slide.value = 1;
      return;
    }
    _slide.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    _motionReduced = chartMotionReduced(context);
    final palette = ChartPalette.of(context);
    final samples = widget.series.samples;
    final highest = samples.fold<double?>(
      null,
      (high, value) =>
          value != null && (high == null || value > high) ? value : high,
    );
    final scaleMax = widget.max ?? chartScaleMax(highest, widget.unit);
    final thresholds = widget.thresholds;

    return Semantics(
      container: true,
      label: chartSeriesSummary(
        label: widget.label,
        samples: samples,
        unit: widget.unit,
        span: scaleMax,
        strings: widget.strings,
      ),
      // The fallback size, for a parent that leaves the sparkline unbounded.
      child: LimitedBox(
        maxWidth: 120,
        maxHeight: 32,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showScale)
              ExcludeSemantics(
                child: Text(
                  formatChartValue(scaleMax, widget.unit, widget.strings),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall!.copyWith(color: palette.scaleText),
                  maxLines: 1,
                ),
              ),
            Expanded(
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: SparklinePainter(
                    series: widget.series,
                    version: widget.series.version,
                    slide: _slide,
                    scaleMax: scaleMax,
                    lineColor: widget.color ?? palette.series.first,
                    warningBand: thresholds == null
                        ? null
                        : (from: thresholds.warning, color: palette.warning),
                    criticalBand: thresholds == null
                        ? null
                        : (from: thresholds.critical, color: palette.critical),
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

/// A threshold band: the value it starts at and its colour.
typedef SparklineBand = ({double from, Color color});

/// Paints a [Sparkline]'s plot; public so painter tests can check what it
/// draws.
final class SparklinePainter extends CustomPainter {
  SparklinePainter({
    required this.series,
    required this.version,
    required this.slide,
    required this.scaleMax,
    required this.lineColor,
    required this.warningBand,
    required this.criticalBand,
  }) : assert(scaleMax > 0, 'the scale needs a positive top'),
       super(repaint: slide);

  final SeriesRing series;

  /// [series]' version when this painter was built: a new one repaints.
  final int version;

  /// The slide-in's progress, 1 at rest.
  final Animation<double> slide;

  final double scaleMax;
  final Color lineColor;
  final SparklineBand? warningBand;
  final SparklineBand? criticalBand;

  static const strokeWidth = 1.5;

  /// A band's wash over the plot, light enough to keep the line legible.
  /// The wash is decoration: the rule at its threshold carries the band's
  /// colour at the strength the palette test checks.
  static const bandAlpha = 0.16;

  static const _ruleWidth = 1.0;

  /// The columns of the last paint, kept while the samples drawn and the
  /// bucket size stay, so the slide's frames do not downsample again.
  List<MinMaxColumn?> _columns = const [];
  ({int version, int bucketSize, int firstIndex})? _columnsKey;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by half the stroke so a line at either end is not clipped.
    final plot = (Offset.zero & size).deflate(strokeWidth / 2);
    if (plot.isEmpty) return;
    double yOf(double value) =>
        plot.bottom - value.clamp(0, scaleMax) / scaleMax * plot.height;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    var bandTop = 0.0;
    for (final band in [criticalBand, warningBand]) {
      if (band == null || band.from >= scaleMax) continue;
      final bottom = yOf(band.from);
      if (bottom <= bandTop) continue;
      canvas.drawRect(
        Rect.fromLTRB(0, bandTop, size.width, bottom),
        Paint()..color = band.color.withValues(alpha: bandAlpha),
      );
      canvas.drawRect(
        Rect.fromLTRB(0, bottom - _ruleWidth, size.width, bottom),
        Paint()..color = band.color,
      );
      bandTop = bottom;
    }
    _paintLine(canvas, plot, yOf);
    canvas.restore();
  }

  void _paintLine(Canvas canvas, Rect plot, double Function(double) yOf) {
    if (series.length == 0) return;

    // While a full ring's new sample slides in, the one it pushed out
    // slides off the left edge instead of vanishing first.
    final samples = slide.value < 1
        ? series.samplesWithEvicted
        : series.samples;
    final firstIndex = series.added - samples.length;
    final step = plot.width / (series.capacity - 1);
    final bucketSize = math.max(1, (series.capacity / plot.width).ceil());
    final key = (
      version: series.version,
      bucketSize: bucketSize,
      firstIndex: firstIndex,
    );
    if (_columnsKey != key) {
      _columnsKey = key;
      _columns = downsampleMinMax(
        samples,
        bucketSize: bucketSize,
        firstIndex: firstIndex,
      );
    }

    final newest = series.added - 1;
    final shift = step * (1 - slide.value);
    final line = Path();
    final dots = <Offset>[];
    Offset? segmentStart;
    var segmentPoints = 0;
    void endSegment() {
      // A known sample between two gaps has no neighbour to join: a dot.
      if (segmentPoints == 1) dots.add(segmentStart!);
      segmentPoints = 0;
    }

    for (final column in _columns) {
      if (column == null) {
        endSegment();
        continue;
      }
      // The column's middle slot, among those still in the ring.
      final from = math.max(column.start, firstIndex);
      final to = math.min(column.start + bucketSize - 1, newest);
      final x = plot.right - (newest - (from + to) / 2) * step + shift;
      for (final value in [
        column.first,
        if (column.second != column.first) column.second,
      ]) {
        final point = Offset(x, yOf(value));
        if (segmentPoints++ == 0) {
          line.moveTo(point.dx, point.dy);
          segmentStart = point;
        } else {
          line.lineTo(point.dx, point.dy);
        }
      }
    }
    endSegment();

    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final dotPaint = Paint()..color = lineColor;
    for (final dot in dots) {
      canvas.drawCircle(dot, strokeWidth, dotPaint);
    }
  }

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) =>
      oldDelegate.version != version ||
      oldDelegate.series != series ||
      oldDelegate.slide != slide ||
      oldDelegate.scaleMax != scaleMax ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.warningBand != warningBand ||
      oldDelegate.criticalBand != criticalBand;
}

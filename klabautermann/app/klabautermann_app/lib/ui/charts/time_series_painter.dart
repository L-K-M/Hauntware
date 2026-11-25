import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;

import 'chart_marks.dart';
import 'chart_values.dart';
import 'time_series.dart';
import 'time_series_crosshair.dart';

/// A band without data in words, as a screen reader hears it and the
/// coverage inspector lists it: when it began and ended, and why.
String chartGapText(ChartGap gap, ChartStrings strings) => switch (gap.end) {
  final end? => strings.gapSummary(
    gap.start,
    end,
    chartGapLabel(gap.reason, strings),
  ),
  null => strings.gapOngoing(gap.start, chartGapLabel(gap.reason, strings)),
};

/// The first time axis tick at or after [from] on a grid of [step]
/// microseconds that falls on round local times in a zone [offset]
/// microseconds off UTC, so a zone half an hour off UTC still reads 12:00
/// rather than 11:30.
int firstTimeSeriesTick({
  required int from,
  required int step,
  required int offset,
}) {
  final local = from + offset;
  final tick = local - local % step - offset;
  return tick < from ? tick + step : tick;
}

/// This device's zone offset from UTC at [time].
Duration deviceZoneOffset(DateTime time) => time.toLocal().timeZoneOffset;

void paintHatch(Canvas canvas, Rect band, Color ink) {
  canvas.save();
  canvas.clipRect(band);
  canvas.drawRect(
    band,
    Paint()..color = ink.withValues(alpha: TimeSeriesPainter.gapWashAlpha),
  );
  final hatch = Path();
  for (
    var x = band.left - band.height;
    x < band.right;
    x += TimeSeriesPainter._gapHatchSpacing
  ) {
    hatch
      ..moveTo(x, band.bottom)
      ..lineTo(x + band.height, band.top);
  }
  canvas.drawPath(
    hatch,
    Paint()
      ..color = ink.withValues(alpha: TimeSeriesPainter._gapHatchAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = TimeSeriesPainter._gapHatchWidth,
  );
  canvas.restore();
}

/// Paints a [TimeSeriesChart]'s plot and axes; visible so painter tests can
/// check what it draws, and kept out of the charts' barrel.
final class TimeSeriesPainter extends CustomPainter {
  TimeSeriesPainter({
    required this.data,
    required this.version,
    required this.from,
    required this.to,
    required this.scaleMax,
    required this.unit,
    required this.strings,
    required this.colors,
    required this.gaps,
    required this.summaries,
    required this.textStyle,
    required this.textScaler,
    required this.textDirection,
    required this.background,
    this.zoneOffsetOf = deviceZoneOffset,
    this.warningBand,
    this.criticalBand,
    this.thresholdSummary,
  }) : assert(to > from, 'the window spans time'),
       assert(scaleMax > 0, 'the scale needs a positive top');

  final TimeSeriesRing data;

  /// [data]'s version when this painter was built: a new one repaints.
  final int version;

  /// The window, in microseconds since the epoch.
  final int from;
  final int to;

  final double scaleMax;
  final ChartUnit unit;
  final ChartStrings strings;

  /// One colour per lane.
  final List<Color> colors;

  /// The gaps in the window.
  final List<ChartGap> gaps;

  /// Each lane's screen-reader summary.
  final List<String> summaries;

  /// The axis and gap label style; its colour also draws the grid, the
  /// ticks and the hatching.
  final TextStyle textStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;

  /// Behind a gap's label, so the hatching does not cross it.
  final Color background;

  /// The zone's offset from UTC at a time; ticks fall on round times in
  /// that zone and their labels read its wall clock. The default is the
  /// device's zone; a test passes a zone that the machine's `TZ` cannot
  /// change.
  final Duration Function(DateTime time) zoneOffsetOf;

  /// The threshold bands behind the lines ([paintThresholdBands]).
  final ThresholdBand? warningBand;
  final ThresholdBand? criticalBand;

  /// The levels [warningBand] and [criticalBand] start at, in words, as a
  /// screen reader hears them; null without them.
  final String? thresholdSummary;

  static const strokeWidth = 1.5;

  /// How far a series' marker reaches right of its centre, with its halo:
  /// the plot stops this far short of the right edge, so the marker on a
  /// sample at the edge shows whole.
  static const markerReach = chartMarkerSize * 0.6 + chartMarkerHalo;

  /// The value grid is decoration: the labels beside it carry the values.
  static const _gridAlpha = 0.24;

  /// A gap band's wash and hatching. The hatching, not the wash, carries
  /// the band. Its strokes are 2 px wide: at one pixel per point a 1 px
  /// diagonal covers no pixel whole, so antialiasing fades all of it. A
  /// test holds each stroke, as drawn, to 3:1 against the wash on the
  /// chart surfaces.
  static const gapWashAlpha = 0.06;
  static const _gapHatchAlpha = 0.8;
  static const _gapHatchWidth = 2.0;
  static const _gapHatchSpacing = 8.0;

  /// A band narrower than this widens around its centre, so a short gap
  /// still shows.
  static const minGapWidth = 3.0;

  static const _tickLength = 4.0;
  static const _labelGap = 6.0;

  /// The time axis takes the first step, in seconds, that leaves room
  /// between labels: 5 s to 30 s, then 1 min to 1 day.
  static final _tickSteps = [
    ...[5, 10, 15, 30],
    for (final minutes in [1, 2, 5, 10, 15, 30, 60, 120, 360, 720, 1440])
      minutes * 60,
  ];

  /// The plot within the last size laid out, inside the axis labels.
  Rect? _plot;
  Size? _plotSize;

  Color get _ink => textStyle.color!;

  TextPainter _text(String text) => TextPainter(
    text: TextSpan(text: text, style: textStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();

  double _widthOf(String text) {
    final painter = _text(text);
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// The value grid's labels: top, middle and zero. The caller disposes
  /// them.
  List<TextPainter> _valueLabels() => [
    for (final share in const [1.0, 0.5, 0.0])
      _text(formatChartValue(scaleMax * share, unit, strings)),
  ];

  /// The plot within [size], inside the axis labels: lines, bands and the
  /// crosshair's rule stay within it.
  Rect plotRectFor(Size size) {
    if (_plotSize == size) return _plot!;
    final labels = _valueLabels();
    final gutter = labels.map((label) => label.width).reduce(math.max);
    final lineHeight = labels.first.height;
    for (final label in labels) {
      label.dispose();
    }
    _plotSize = size;
    return _plot = Rect.fromLTRB(
      gutter + _labelGap,
      lineHeight / 2,
      size.width - markerReach,
      size.height - lineHeight - _tickLength - 2,
    );
  }

  /// Where the time [micros] falls across [plot].
  double xOf(Rect plot, int micros) =>
      plot.left + (micros - from) / (to - from) * plot.width;

  /// Where [value] falls up [plot], clamped to the scale.
  double yOf(Rect plot, double value) =>
      plot.bottom - value.clamp(0, scaleMax) / scaleMax * plot.height;

  Rect _bandOf(Rect plot, ChartGap gap) {
    final start = math.max(gap.start.microsecondsSinceEpoch, from);
    final end = math.min(gap.end?.microsecondsSinceEpoch ?? to, to);
    final band = Rect.fromLTRB(
      xOf(plot, start),
      plot.top,
      xOf(plot, end),
      plot.bottom,
    );
    if (band.width >= minGapWidth) return band;
    return Rect.fromCenter(
      center: band.center,
      width: minGapWidth,
      height: band.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotRectFor(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    double yOf(double value) => this.yOf(plot, value);

    paintThresholdBands(
      canvas,
      plot,
      yOf: yOf,
      scaleMax: scaleMax,
      warning: warningBand,
      critical: criticalBand,
    );

    final grid = Paint()..color = _ink.withValues(alpha: _gridAlpha);
    final valueLabels = _valueLabels();
    for (final (index, label) in valueLabels.indexed) {
      final y = yOf(scaleMax * (1 - index / 2));
      canvas.drawRect(
        Rect.fromLTRB(plot.left, y - 0.5, plot.right, y + 0.5),
        grid,
      );
      label.paint(
        canvas,
        Offset(plot.left - _labelGap - label.width, y - label.height / 2),
      );
      label.dispose();
    }

    for (final gap in gaps) {
      final band = _bandOf(plot, gap).intersect(plot);
      paintHatch(canvas, band, _ink);
      final label = _text(chartGapLabel(gap.reason, strings));
      // The label sits on a backing that leaves the band's edges showing.
      final box = Rect.fromCenter(
        center: Offset(band.center.dx, band.top + 2 + label.height / 2),
        width: label.width + _labelGap,
        height: label.height,
      );
      if (box.width + 2 <= band.width) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(3)),
          Paint()..color = background,
        );
        label.paint(canvas, box.topLeft + const Offset(_labelGap / 2, 0));
      }
      label.dispose();
    }

    _paintLines(canvas, plot, yOf);
    _paintTimeAxis(canvas, size, plot);
  }

  void _paintLines(Canvas canvas, Rect plot, double Function(double) yOf) {
    final bucket = math.max(1, ((to - from) / plot.width).ceil());
    canvas.save();
    // Lines stop at the time edges; a value at zero or the top keeps its
    // full stroke.
    canvas.clipRect(
      Rect.fromLTRB(
        plot.left,
        plot.top - strokeWidth,
        plot.right,
        plot.bottom + strokeWidth,
      ),
    );
    final markers = <(ChartMarker, Offset, Color)>[];
    for (var lane = 0; lane < data.lanes; lane++) {
      final line = Path();
      final dots = <Offset>[];
      final runs = timeSeriesRuns(
        data,
        lane,
        from: from,
        to: to,
        bucket: bucket,
      );
      for (final run in runs) {
        final points = [
          for (final index in run)
            Offset(
              xOf(plot, data.microsAt(index)),
              yOf(data.valueAt(lane, index)!),
            ),
        ];
        if (points.length == 1) {
          dots.add(points.single);
          continue;
        }
        line.addPolygon(points, false);
      }
      final color = colors[lane];
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      final dotPaint = Paint()..color = color;
      for (final dot in dots) {
        canvas.drawCircle(dot, strokeWidth, dotPaint);
      }
      if (_latestInView(runs) case final index?) {
        markers.add((
          ChartMarker.forLane(lane),
          Offset(
            xOf(plot, data.microsAt(index)),
            yOf(data.valueAt(lane, index)!),
          ),
          color,
        ));
      }
    }
    canvas.restore();
    // Outside the clip, so a marker at zero or the top shows whole.
    for (final (marker, center, color) in markers) {
      paintChartMarker(canvas, marker, center, color, halo: background);
    }
  }

  /// The newest sample of [runs] inside the window, where the lane's marker
  /// goes: the runs reach one sample past either edge, so only the last
  /// run's last few entries are looked at.
  int? _latestInView(List<List<int>> runs) {
    for (final run in runs.reversed) {
      for (final index in run.reversed) {
        final micros = data.microsAt(index);
        if (micros > to) continue;
        return micros >= from ? index : null;
      }
    }
    return null;
  }

  void _paintTimeAxis(Canvas canvas, Size size, Rect plot) {
    final edge = DateTime.fromMicrosecondsSinceEpoch(to);
    final minuteWidth = _widthOf(strings.time(edge));
    final secondWidth = _widthOf(strings.timeWithSeconds(edge));
    final perSecond =
        plot.width / ((to - from) / Duration.microsecondsPerSecond);
    final step = _tickSteps.firstWhere(
      (step) =>
          step * perSecond >=
          (step < 60 ? secondWidth : minuteWidth) + 2 * _labelGap,
      orElse: () => _tickSteps.last,
    );

    final stepMicros = step * Duration.microsecondsPerSecond;
    var tick = firstTimeSeriesTick(
      from: from,
      step: stepMicros,
      offset: zoneOffsetOf(edge).inMicroseconds,
    );

    final tickPaint = Paint()..color = _ink;
    for (; tick <= to; tick += stepMicros) {
      final x = xOf(plot, tick);
      canvas.drawRect(
        Rect.fromLTWH(x - 0.5, plot.bottom, 1, _tickLength),
        tickPaint,
      );
      final utc = DateTime.fromMicrosecondsSinceEpoch(tick, isUtc: true);
      // Fields that read the zone's wall clock; only they are formatted.
      final time = utc.add(zoneOffsetOf(utc));
      final label = _text(
        step < 60 ? strings.timeWithSeconds(time) : strings.time(time),
      );
      final left = x - label.width / 2;
      if (left >= 0 && left + label.width <= size.width) {
        label.paint(canvas, Offset(left, plot.bottom + _tickLength + 2));
      }
      label.dispose();
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final plot = plotRectFor(size);
    CustomPainterSemantics node(Rect rect, String label) =>
        CustomPainterSemantics(
          rect: rect,
          properties: SemanticsProperties(
            label: label,
            textDirection: textDirection,
          ),
        );
    // Large text can leave no room for a plot, and so no bands, but the
    // summaries still carry the data.
    if (plot.width <= 0 || plot.height <= 0) {
      return [
        for (final summary in summaries) node(Offset.zero & size, summary),
      ];
    }
    return [
      for (final summary in summaries) node(plot, summary),
      for (final gap in gaps)
        node(_bandOf(plot, gap).intersect(plot), chartGapText(gap, strings)),
      if (thresholdSummary case final levels?) node(plot, levels),
    ];
  };

  @override
  bool shouldRepaint(TimeSeriesPainter oldDelegate) =>
      oldDelegate.version != version ||
      oldDelegate.data != data ||
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.scaleMax != scaleMax ||
      oldDelegate.unit != unit ||
      oldDelegate.strings != strings ||
      !listEquals(oldDelegate.colors, colors) ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.background != background ||
      oldDelegate.zoneOffsetOf != zoneOffsetOf ||
      oldDelegate.warningBand != warningBand ||
      oldDelegate.criticalBand != criticalBand;

  @override
  bool shouldRebuildSemantics(TimeSeriesPainter oldDelegate) =>
      shouldRepaint(oldDelegate) ||
      !listEquals(oldDelegate.summaries, summaries) ||
      oldDelegate.thresholdSummary != thresholdSummary;
}

/// Paints a [TimeSeriesChart]'s crosshair over its plot: a rule at [hit]
/// and, on a sample, each known value's marker on it. It reads [chart]'s
/// plot and scale, so a new chart painter repaints it too. Visible so
/// painter tests can check what it draws, and kept out of the charts'
/// barrel.
final class TimeSeriesCrosshairPainter extends CustomPainter {
  TimeSeriesCrosshairPainter({
    required this.chart,
    required this.hit,
    required this.ink,
  });

  final TimeSeriesPainter chart;
  final TimeSeriesHit hit;

  /// The rule's colour: the axis text's, at full strength.
  final Color ink;

  static const ruleWidth = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = chart.plotRectFor(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    final hit = this.hit;
    final x = chart.xOf(plot, hit.at);
    canvas.drawRect(
      Rect.fromLTRB(
        x - ruleWidth / 2,
        plot.top,
        x + ruleWidth / 2,
        plot.bottom,
      ),
      Paint()..color = ink,
    );
    if (hit is! TimeSeriesSampleHit) return;
    final data = chart.data;
    for (var lane = 0; lane < data.lanes; lane++) {
      final value = data.valueAt(lane, hit.index);
      if (value == null) continue;
      paintChartMarker(
        canvas,
        ChartMarker.forLane(lane),
        Offset(x, chart.yOf(plot, value)),
        chart.colors[lane],
        halo: chart.background,
      );
    }
  }

  @override
  bool shouldRepaint(TimeSeriesCrosshairPainter oldDelegate) =>
      oldDelegate.chart != chart ||
      oldDelegate.hit != hit ||
      oldDelegate.ink != ink;
}

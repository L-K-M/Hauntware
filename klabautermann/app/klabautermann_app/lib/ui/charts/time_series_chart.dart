import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;

import 'chart_style.dart';
import 'chart_values.dart';
import 'time_series.dart';

/// A time-series chart (03 §10.7, OV-03): the one to four lanes of a
/// [TimeSeriesRing] on a shared time axis that spans [span] and ends at
/// [end], on one scale from zero with IEC or percent labels (A11Y-06).
///
/// No line crosses an unknown sample or a gap, and every gap is a hatched
/// band labelled with its reason where the label fits. The legend names
/// each series, each gap reason in view and the data's [source] (03 §9.5
/// item 5), so a band too narrow for its label is still named. Screen
/// readers get each series' summary over the window (A11Y-02) and each
/// gap's span, none of them a live region (A11Y-15).
///
/// The chart rebuilds on each change to [data]; its painter repaints on
/// the ring's version counter inside its own [RepaintBoundary]. It moves
/// only when a sample arrives or a rebuild hands it a later [end], and it
/// never animates, so reduced motion (A11Y-11) leaves it unchanged.
///
/// On an axis its parent leaves unbounded, and when measured intrinsically,
/// the chart takes 320 x 200.
class TimeSeriesChart extends StatelessWidget {
  const TimeSeriesChart({
    super.key,
    required this.data,
    required this.labels,
    required this.unit,
    required this.strings,
    required this.source,
    required this.end,
    this.span = const Duration(minutes: 10),
    this.max,
    this.zoneOffset,
  });

  final TimeSeriesRing data;

  /// One label per lane, as the legend and the summaries name the series.
  final List<String> labels;

  final ChartUnit unit;
  final ChartStrings strings;

  /// Where the samples come from, as the legend names it: for example that
  /// this device recorded them while it was connected.
  final String source;

  /// The time at the right edge, usually now; an open gap reaches it.
  final DateTime end;

  /// How much time the chart shows.
  final Duration span;

  /// The top of the scale; null scales to the data in view
  /// ([chartScaleMax]).
  final double? max;

  /// The fixed zone offset the time axis reads, such as a server's when
  /// the time display shows server times (A11Y-07); null for this
  /// device's zone.
  final Duration? zoneOffset;

  @override
  Widget build(BuildContext context) {
    assert(labels.length == data.lanes, 'one label per lane');
    return ListenableBuilder(listenable: data, builder: _build);
  }

  Widget _build(BuildContext context, Widget? _) {
    final theme = Theme.of(context);
    final palette = ChartPalette.of(context);
    final to = end.microsecondsSinceEpoch;
    final from = to - span.inMicroseconds;

    final first = data.indexAtOrAfter(from);
    final stop = data.indexAtOrAfter(to + 1);
    final inView = [
      for (var lane = 0; lane < data.lanes; lane++)
        [
          for (var index = first; index < stop; index++)
            data.valueAt(lane, index),
        ],
    ];
    final highest = inView
        .expand((samples) => samples)
        .fold<double?>(
          null,
          (high, value) =>
              value != null && (high == null || value > high) ? value : high,
        );
    final scaleMax = max ?? chartScaleMax(highest, unit);

    final gaps = [
      for (final gap in data.gaps)
        if (gap.start.microsecondsSinceEpoch < to &&
            (gap.end?.microsecondsSinceEpoch ?? to) > from)
          gap,
    ];
    // While the right edge lies in a gap no value is current, so the last
    // sample before it must not read as now (03 §10.4).
    final lastGap = gaps.lastOrNull;
    final edgeInGap =
        lastGap != null &&
        (lastGap.end == null || lastGap.end!.microsecondsSinceEpoch > to);
    final style = theme.textTheme.labelSmall!.copyWith(
      color: palette.scaleText,
    );

    final plot = RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: TimeSeriesPainter(
          data: data,
          version: data.version,
          from: from,
          to: to,
          scaleMax: scaleMax,
          unit: unit,
          strings: strings,
          colors: palette.series,
          gaps: gaps,
          summaries: [
            for (final (lane, samples) in inView.indexed)
              chartSeriesSummary(
                label: labels[lane],
                samples: edgeInGap ? [...samples, null] : samples,
                unit: unit,
                span: scaleMax,
                strings: strings,
              ),
          ],
          textStyle: style,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          background: theme.colorScheme.surface,
          zoneOffsetOf: switch (zoneOffset) {
            final offset? => (_) => offset,
            null => _deviceZoneOffset,
          },
        ),
      ),
    );
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              for (final (lane, label) in labels.indexed)
                _legendEntry(
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.series[lane],
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                    child: const SizedBox(width: 12, height: 3),
                  ),
                  label,
                  theme.textTheme.labelSmall!,
                ),
              for (final reason in {for (final gap in gaps) gap.reason})
                _legendEntry(
                  CustomPaint(
                    size: const Size(12, 10),
                    painter: _HatchSwatch(palette.scaleText),
                  ),
                  _gapLabel(reason, strings),
                  style,
                ),
            ],
          ),
        ),
        Text(source, style: style),
      ],
    );

    return Semantics(
      container: true,
      child: CustomMultiChildLayout(
        delegate: _ChartLayout(),
        children: [
          LayoutId(id: _ChartPart.plot, child: plot),
          LayoutId(
            id: _ChartPart.legend,
            // On a phone it would otherwise take the route's primary
            // controller, which only one scroll view may hold, and scroll
            // on a status-bar tap.
            child: SingleChildScrollView(primary: false, child: legend),
          ),
        ],
      ),
    );
  }

  /// A label wider than the chart, such as a long series name or one
  /// under large text, wraps within its entry.
  static Widget _legendEntry(Widget swatch, String label, TextStyle style) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          swatch,
          Flexible(child: Text(label, style: style)),
        ],
      );
}

enum _ChartPart { plot, legend }

/// Lays the plot out above the legend and the source. Large text may not
/// squeeze the plot out: the legend and the source take at most half the
/// height and scroll within it. Unlike a [LayoutBuilder], this layout
/// answers intrinsic measurements, so the chart can sit in an
/// [IntrinsicHeight] row.
final class _ChartLayout extends MultiChildLayoutDelegate {
  /// The size on an axis the parent leaves unbounded, which is also what
  /// an intrinsic measurement gets.
  static const _fallback = Size(320, 200);
  static const _legendGap = 4.0;

  @override
  Size getSize(BoxConstraints constraints) => Size(
    constraints.hasBoundedWidth ? constraints.maxWidth : _fallback.width,
    constraints.hasBoundedHeight ? constraints.maxHeight : _fallback.height,
  );

  @override
  void performLayout(Size size) {
    // At the full width the legend's column puts its rows at the start
    // edge, on the right in right-to-left text.
    final legend = layoutChild(
      _ChartPart.legend,
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: size.height / 2,
      ),
    );
    positionChild(_ChartPart.legend, Offset(0, size.height - legend.height));
    final plotHeight = size.height - legend.height - _legendGap;
    layoutChild(
      _ChartPart.plot,
      BoxConstraints.tight(Size(size.width, math.max(0, plotHeight))),
    );
  }

  @override
  bool shouldRelayout(_ChartLayout oldDelegate) => false;
}

String _gapLabel(ChartGapReason reason, ChartStrings strings) =>
    switch (reason) {
      ChartGapReason.appClosed => strings.gapAppClosed,
      ChartGapReason.background => strings.gapBackground,
      ChartGapReason.disconnected => strings.gapDisconnected,
      ChartGapReason.readingFailed => strings.gapReadingFailed,
    };

/// A band without data in words, as a screen reader hears it and the
/// coverage inspector lists it: when it began and ended, and why.
String chartGapText(ChartGap gap, ChartStrings strings) => switch (gap.end) {
  final end? => strings.gapSummary(
    gap.start,
    end,
    _gapLabel(gap.reason, strings),
  ),
  null => strings.gapOngoing(gap.start, _gapLabel(gap.reason, strings)),
};

/// The first time axis tick at or after [from] on a grid of [step]
/// microseconds that falls on round local times in a zone [offset]
/// microseconds off UTC, so a zone half an hour off UTC still reads 12:00
/// rather than 11:30.
@visibleForTesting
int firstTimeSeriesTick({
  required int from,
  required int step,
  required int offset,
}) {
  final local = from + offset;
  final tick = local - local % step - offset;
  return tick < from ? tick + step : tick;
}

Duration _deviceZoneOffset(DateTime time) => time.toLocal().timeZoneOffset;

void _paintHatch(Canvas canvas, Rect band, Color ink) {
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

final class _HatchSwatch extends CustomPainter {
  _HatchSwatch(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) =>
      _paintHatch(canvas, Offset.zero & size, ink);

  @override
  bool shouldRepaint(_HatchSwatch oldDelegate) => oldDelegate.ink != ink;
}

/// Paints a [TimeSeriesChart]'s plot and axes; visible so painter tests can
/// check what it draws, and kept out of the charts' barrel.
@visibleForTesting
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
    this.zoneOffsetOf = _deviceZoneOffset,
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

  static const strokeWidth = 1.5;

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

  Rect _plotFor(Size size) {
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
      size.width - strokeWidth / 2,
      size.height - lineHeight - _tickLength - 2,
    );
  }

  double _xOf(Rect plot, int micros) =>
      plot.left + (micros - from) / (to - from) * plot.width;

  Rect _bandOf(Rect plot, ChartGap gap) {
    final start = math.max(gap.start.microsecondsSinceEpoch, from);
    final end = math.min(gap.end?.microsecondsSinceEpoch ?? to, to);
    final band = Rect.fromLTRB(
      _xOf(plot, start),
      plot.top,
      _xOf(plot, end),
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
    final plot = _plotFor(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    double yOf(double value) =>
        plot.bottom - value.clamp(0, scaleMax) / scaleMax * plot.height;

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
      _paintHatch(canvas, band, _ink);
      final label = _text(_gapLabel(gap.reason, strings));
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
              _xOf(plot, data.microsAt(index)),
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
    }
    canvas.restore();
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
      final x = _xOf(plot, tick);
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
    final plot = _plotFor(size);
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
      oldDelegate.zoneOffsetOf != zoneOffsetOf;

  @override
  bool shouldRebuildSemantics(TimeSeriesPainter oldDelegate) =>
      shouldRepaint(oldDelegate) ||
      !listEquals(oldDelegate.summaries, summaries);
}

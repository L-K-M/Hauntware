import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsProperties;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'chart_marks.dart';
import 'chart_style.dart';
import 'chart_values.dart';
import 'time_series.dart';
import 'time_series_crosshair.dart';

/// A time-series chart (03 §10.7, OV-03): the one to four lanes of a
/// [TimeSeriesRing] on a shared time axis that spans [span] and ends at
/// [end], on one scale from zero with IEC or percent labels (A11Y-06).
///
/// No line crosses an unknown sample or a gap, and every gap is a hatched
/// band labelled with its reason where the label fits. The legend names
/// each series, each gap reason in view and the data's [source] (03 §9.5
/// item 5), so a band too narrow for its label is still named. Each series
/// also has a shape (03 §10.10: never colour alone), drawn beside its name
/// in the legend and at its latest point in view, so a legend entry
/// matches its line without colour; a dash pattern would read as missed
/// samples, so the lines stay solid. [thresholds] draw warning and
/// critical bands with a rule at each level, as the sparkline does, and
/// the legend names each level.
///
/// A crosshair (03 §10.7) follows a hovering mouse or a dragging finger,
/// and the left and right arrow keys (Home and End for the ends) while
/// the chart has focus: a rule at the nearest sample time, each series'
/// shape on it, and beside it a readout of the time in the ticks' zone and
/// each series' value there, or inside a gap that there is no reading and
/// why. Screen readers get each series' summary over the window (A11Y-02)
/// and each gap's span, none of them a live region (A11Y-15), and the
/// readout as an adjustable value that swiping up or down moves.
///
/// The chart rebuilds on each change to [data]; its painter repaints on
/// the ring's version counter inside its own [RepaintBoundary]. The
/// crosshair paints in a layer of its own, so moving it neither rebuilds
/// the chart nor repaints its lines. It moves only when a sample arrives
/// or a rebuild hands it a later [end], and it never animates, so reduced
/// motion (A11Y-11) leaves it unchanged.
///
/// On an axis its parent leaves unbounded, and when measured intrinsically,
/// the chart takes 320 x 200.
class TimeSeriesChart extends StatefulWidget {
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
    this.thresholds,
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

  /// Draws warning and critical bands behind the lines, in [unit]. A level
  /// above the scale draws nothing and the legend leaves it out.
  final ChartThresholds? thresholds;

  @override
  State<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

/// Where the crosshair is: under a pointer, kept as its place on the plot
/// so a moving window slides the data under a still mouse, or at a time a
/// key or a screen reader moved it to.
sealed class _Cursor {
  const _Cursor();
}

final class _PointerCursor extends _Cursor {
  const _PointerCursor(this.x, this.plotSize);

  final double x;
  final Size plotSize;
}

final class _TimeCursor extends _Cursor {
  const _TimeCursor(this.at);

  final int at;
}

final class _StepIntent extends Intent {
  const _StepIntent(this.step);

  final TimeSeriesStep step;
}

/// What the last build drew, which input between builds resolves against.
typedef _Frame = ({
  TimeSeriesPainter chart,
  List<ChartGap> gaps,
  TimeSeriesHit? Function(_Cursor? cursor) hitOf,
});

class _TimeSeriesChartState extends State<TimeSeriesChart> {
  static const _shortcuts = {
    SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(
      TimeSeriesStep.earlier,
    ),
    SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(
      TimeSeriesStep.later,
    ),
    SingleActivator(LogicalKeyboardKey.home): _StepIntent(
      TimeSeriesStep.oldest,
    ),
    SingleActivator(LogicalKeyboardKey.end): _StepIntent(TimeSeriesStep.newest),
  };

  /// The crosshair, which only its layer and the readout's semantics
  /// listen to.
  final _cursor = ValueNotifier<_Cursor?>(null);
  final _focus = FocusNode();
  late final _actions = <Type, Action<Intent>>{
    _StepIntent: CallbackAction<_StepIntent>(
      onInvoke: (intent) => _step(intent.step),
    ),
  };

  /// Whether focus came by keyboard, which draws the focus ring.
  bool _focusRing = false;

  /// Set by each build and each plot layout, for the key and gesture
  /// handlers that run between them.
  _Frame? _frame;
  Size _plotSize = Size.zero;

  /// What started a drag: a mouse that lets go still hovers, so only a
  /// touch or a pen clears the crosshair.
  PointerDeviceKind? _dragKind;

  @override
  void didUpdateWidget(TimeSeriesChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _cursor.value = null;
  }

  @override
  void dispose() {
    _cursor.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _point(Offset position) =>
      _cursor.value = _PointerCursor(position.dx, _plotSize);

  void _leave() {
    if (_cursor.value is _PointerCursor) _cursor.value = null;
  }

  void _endDrag() {
    if (_dragKind != PointerDeviceKind.mouse) _leave();
    _dragKind = null;
  }

  /// Where [step] takes the crosshair from [cursor], or null with nothing
  /// in view.
  int? _stepFrom(_Cursor? cursor, TimeSeriesStep step) {
    final frame = _frame;
    if (frame == null) return null;
    final chart = frame.chart;
    final plot = chart.plotRectFor(_plotSize);
    // One pixel column's time, so each key moves the rule on screen.
    final stride = plot.width > 0
        ? ((chart.to - chart.from) / plot.width).ceil()
        : 1;
    return timeSeriesStepFrom(
      chart.data,
      frame.gaps,
      at: frame.hitOf(cursor)?.at,
      step: step,
      from: chart.from,
      to: chart.to,
      stride: stride,
    );
  }

  void _step(TimeSeriesStep step) {
    final at = _stepFrom(_cursor.value, step);
    if (at != null) _cursor.value = _TimeCursor(at);
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.labels.length == widget.data.lanes, 'one label per lane');
    return ListenableBuilder(listenable: widget.data, builder: _build);
  }

  Widget _build(BuildContext context, Widget? _) {
    final TimeSeriesChart(:data, :labels, :unit, :strings) = widget;
    final theme = Theme.of(context);
    final palette = ChartPalette.of(context);
    final to = widget.end.microsecondsSinceEpoch;
    final from = to - widget.span.inMicroseconds;

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
    final scaleMax = widget.max ?? chartScaleMax(highest, unit);

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
    String format(double value) => formatChartValue(value, unit, strings);

    // The levels the plot draws, as the legend and screen readers name them.
    final thresholds = widget.thresholds;
    final levels = [
      if (thresholds != null)
        for (final (level, severity, color) in [
          (thresholds.warning, strings.severityWarning, palette.warning),
          (thresholds.critical, strings.severityCritical, palette.critical),
        ])
          if (level.isFinite && level < scaleMax)
            (strings.barPart(severity, format(math.max(0, level))), color),
    ];
    ThresholdBand? band(double? level, Color color) =>
        level == null ? null : (from: level, color: color);

    final zoneOffsetOf = switch (widget.zoneOffset) {
      final offset? => (DateTime _) => offset,
      null => _deviceZoneOffset,
    };
    final chart = TimeSeriesPainter(
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
      zoneOffsetOf: zoneOffsetOf,
      warningBand: band(thresholds?.warning, palette.warning),
      criticalBand: band(thresholds?.critical, palette.critical),
      thresholdSummary: levels.isEmpty
          ? null
          : [
              for (final (words, _) in levels) words,
            ].join(strings.listSeparator),
    );

    TimeSeriesHit? hitOf(_Cursor? cursor) {
      switch (cursor) {
        case null:
          return null;
        case _TimeCursor(:final at):
          return timeSeriesHitAt(data, gaps, at: at, from: from, to: to);
        case _PointerCursor(:final x, :final plotSize):
          final plot = chart.plotRectFor(plotSize);
          if (plot.width <= 0 || plot.height <= 0) return null;
          final window = to - from;
          return timeSeriesHitAt(
            data,
            gaps,
            at: from + ((x - plot.left) / plot.width * window).round(),
            from: from,
            to: to,
            // A narrow band is drawn wider than its span, and a pointer
            // over any of it finds the gap.
            gapReach: (TimeSeriesPainter.minGapWidth / 2 / plot.width * window)
                .ceil(),
          );
      }
    }

    _frame = (chart: chart, gaps: gaps, hitOf: hitOf);
    TimeSeriesReadout readoutOf(TimeSeriesHit hit) => timeSeriesReadout(
      hit,
      data,
      labels: labels,
      unit: unit,
      strings: strings,
      span: widget.span,
      zoneOffsetOf: zoneOffsetOf,
    );

    final layer = ValueListenableBuilder(
      valueListenable: _cursor,
      builder: (context, cursor, _) {
        final hit = hitOf(cursor);
        if (hit == null) return const SizedBox.shrink();
        final plot = chart.plotRectFor(_plotSize);
        return ExcludeSemantics(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: TimeSeriesCrosshairPainter(
                  chart: chart,
                  hit: hit,
                  ink: palette.scaleText,
                ),
              ),
              CustomSingleChildLayout(
                delegate: _ReadoutLayout(
                  x: chart.xOf(plot, hit.at),
                  top: plot.top,
                  minSide: MediaQuery.textScalerOf(context).scale(96),
                ),
                child: _Readout(
                  readout: readoutOf(hit),
                  colors: palette.series,
                  ink: palette.scaleText,
                ),
              ),
            ],
          ),
        );
      },
    );

    Widget plot = MouseRegion(
      onHover: (event) => _point(event.localPosition),
      onExit: (_) => _leave(),
      child: GestureDetector(
        // Screen readers move the crosshair through the readout's
        // adjustable node; a long press or a scroll would do nothing more.
        excludeFromSemantics: true,
        onHorizontalDragStart: (details) {
          _dragKind = details.kind;
          _point(details.localPosition);
        },
        onHorizontalDragUpdate: (details) => _point(details.localPosition),
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        onLongPressStart: (details) => _point(details.localPosition),
        onLongPressMoveUpdate: (details) => _point(details.localPosition),
        onLongPressEnd: (_) => _endDrag(),
        onLongPressCancel: _endDrag,
        // The plot's own size, which a pointer's place is relative to; the
        // chart's layout answers intrinsic measurements without it.
        child: LayoutBuilder(
          builder: (context, constraints) {
            _plotSize = constraints.biggest;
            return Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(size: Size.infinite, painter: chart),
                ),
                layer,
              ],
            );
          },
        ),
      ),
    );
    if (_focusRing) {
      plot = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.primary, width: 2),
          borderRadius: BorderRadius.circular(2),
        ),
        child: plot,
      );
    }
    plot = FocusableActionDetector(
      focusNode: _focus,
      shortcuts: _shortcuts,
      actions: _actions,
      onFocusChange: (focused) {
        if (!focused && _cursor.value is _TimeCursor) _cursor.value = null;
      },
      onShowFocusHighlight: (show) => setState(() => _focusRing = show),
      child: plot,
    );
    // The readout as a screen reader meets it: an adjustable value, as a
    // slider is, that moves the crosshair. Its value changes only when the
    // user moves it, so it is no live region (A11Y-15).
    plot = ValueListenableBuilder(
      valueListenable: _cursor,
      child: plot,
      builder: (context, cursor, child) {
        String? words(_Cursor? cursor) => switch (hitOf(cursor)) {
          final hit? => timeSeriesReadoutText(readoutOf(hit), strings),
          null => null,
        };
        String? wordsAfter(TimeSeriesStep step) =>
            switch (_stepFrom(cursor, step)) {
              final at? => words(_TimeCursor(at)),
              null => null,
            };
        // Until the crosshair shows, the readout has no value, and so no
        // value either side of it.
        final value = words(cursor);
        return Semantics(
          container: true,
          label: strings.readout,
          value: value,
          increasedValue: value == null
              ? null
              : wordsAfter(TimeSeriesStep.later),
          decreasedValue: value == null
              ? null
              : wordsAfter(TimeSeriesStep.earlier),
          onIncrease: () => _step(TimeSeriesStep.later),
          onDecrease: () => _step(TimeSeriesStep.earlier),
          child: child,
        );
      },
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
                  CustomPaint(
                    size: _LaneSwatch.size,
                    painter: _LaneSwatch(
                      palette.series[lane],
                      ChartMarker.forLane(lane),
                    ),
                  ),
                  label,
                  theme.textTheme.labelSmall!,
                ),
              for (final (words, color) in levels)
                _legendEntry(
                  SizedBox.fromSize(
                    size: _LaneSwatch.size,
                    child: Center(
                      child: SizedBox(
                        width: _LaneSwatch.size.width,
                        height: 2,
                        child: ColoredBox(color: color),
                      ),
                    ),
                  ),
                  words,
                  style,
                ),
              for (final reason in {for (final gap in gaps) gap.reason})
                _legendEntry(
                  CustomPaint(
                    size: const Size(12, 10),
                    painter: _HatchSwatch(palette.scaleText),
                  ),
                  chartGapLabel(reason, strings),
                  style,
                ),
            ],
          ),
        ),
        Text(widget.source, style: style),
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

/// A series' legend swatch: a stroke of its line with its marker on it.
final class _LaneSwatch extends CustomPainter {
  _LaneSwatch(this.color, this.marker, {this.line = true});

  static const size = Size(16, 10);

  final Color color;
  final ChartMarker marker;

  /// Whether the stroke shows; the readout shows the marker alone.
  final bool line;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (line) {
      canvas.drawRect(
        Rect.fromCenter(
          center: center,
          width: size.width,
          height: TimeSeriesPainter.strokeWidth,
        ),
        Paint()..color = color,
      );
    }
    paintChartMarker(canvas, marker, center, color);
  }

  @override
  bool shouldRepaint(_LaneSwatch oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.marker != marker ||
      oldDelegate.line != line;
}

/// The crosshair's readout: the time, then each series' shape with its
/// label and value, or inside a gap that there is no reading and why. It
/// wraps at the width it is given and scales down rather than overflow a
/// short plot under large text. Screen readers hear it through the
/// chart's adjustable readout node instead.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.readout,
    required this.colors,
    required this.ink,
  });

  final TimeSeriesReadout readout;
  final List<Color> colors;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall!;
    final gap = readout.gap;
    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(
              readout.time,
              style: style.copyWith(fontWeight: FontWeight.w600),
            ),
            for (final (lane, value) in readout.values.indexed)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  CustomPaint(
                    size: const Size.square(chartMarkerSize + 2),
                    painter: _LaneSwatch(
                      colors[lane],
                      ChartMarker.forLane(lane),
                      line: false,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      value,
                      style: style.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            if (gap != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  CustomPaint(
                    size: const Size(12, 10),
                    painter: _HatchSwatch(ink),
                  ),
                  Flexible(child: Text(gap, style: style)),
                ],
              ),
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: body,
        ),
      ),
    );
  }
}

/// Places the readout beside the crosshair's rule at [x], after it where
/// it fits and otherwise before it, so it does not cover the points it
/// describes. It wraps to the wider side, unless that side is narrower
/// than [minSide]; only then does it take the plot's width and may cover
/// the rule.
final class _ReadoutLayout extends SingleChildLayoutDelegate {
  _ReadoutLayout({required this.x, required this.top, required this.minSide});

  final double x;
  final double top;
  final double minSide;

  static const _gap = chartMarkerSize;

  double _after(Size size) => size.width - x - _gap;
  double _before() => x - _gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final side = math.max(_after(size), _before());
    return BoxConstraints.loose(
      Size(side >= minSide ? side : size.width, size.height),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final y = math.max(0.0, math.min(top, size.height - childSize.height));
    if (childSize.width <= _after(size)) return Offset(x + _gap, y);
    if (childSize.width <= _before()) {
      return Offset(x - _gap - childSize.width, y);
    }
    final left = _after(size) >= _before()
        ? x + _gap
        : x - _gap - childSize.width;
    return Offset(
      left.clamp(0.0, math.max(0.0, size.width - childSize.width)),
      y,
    );
  }

  @override
  bool shouldRelayout(_ReadoutLayout oldDelegate) =>
      oldDelegate.x != x ||
      oldDelegate.top != top ||
      oldDelegate.minSide != minSide;
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
      _paintHatch(canvas, band, _ink);
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
@visibleForTesting
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

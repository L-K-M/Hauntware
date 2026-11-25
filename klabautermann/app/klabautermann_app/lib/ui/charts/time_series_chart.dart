import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'chart_marks.dart';
import 'chart_style.dart';
import 'chart_values.dart';
import 'time_series.dart';
import 'time_series_crosshair.dart';
import 'time_series_painter.dart';
import 'time_series_readout.dart';

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
      null => deviceZoneOffset,
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
                delegate: ReadoutLayout(
                  x: chart.xOf(plot, hit.at),
                  top: plot.top,
                  minSide: MediaQuery.textScalerOf(context).scale(96),
                ),
                child: Readout(
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
                    size: LaneSwatch.size,
                    painter: LaneSwatch(
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
                    size: LaneSwatch.size,
                    child: Center(
                      child: SizedBox(
                        width: LaneSwatch.size.width,
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
                    painter: HatchSwatch(palette.scaleText),
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

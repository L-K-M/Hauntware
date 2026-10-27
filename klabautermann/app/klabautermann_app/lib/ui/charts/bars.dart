import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_style.dart';
import 'chart_values.dart';

/// One part of a [StackedBar]: what it measures, as the legend and the
/// summary name it, and its value in the bar's unit, null when the host did
/// not report it.
@immutable
final class BarSegment {
  const BarSegment({required this.label, required this.value});

  final String label;
  final double? value;
}

/// One metric of a [PressureBar]: its name, its share from 0 to 100 (null
/// when the host did not report it), and the levels past which it takes
/// the warning or critical colour.
@immutable
final class PressureCell {
  const PressureCell({
    required this.label,
    required this.percent,
    this.thresholds,
  });

  final String label;
  final double? percent;
  final ChartThresholds? thresholds;
}

/// A stacked bar (03 §10.7; MEM-01, DSK-01): [segments] side by side in the
/// series colours on a track that stands for [total], such as used memory,
/// buffers and cache out of the installed memory.
///
/// Segments stack in order, and any part past [total] is cut at its end. A
/// segment the host did not report is never drawn as zero (03 §10.4): the
/// bar hatches everything past the segments it knows, because it cannot
/// tell that segment from free space, and an unknown total hatches the
/// whole bar. [thresholds] judge the first segment's share of [total] in
/// percent, the figure the bar is about (used memory, used disk): past a
/// level that segment takes the severity colour with a stripe of the track
/// through it, an icon beside the bar shows the severity by its shape, and
/// the legend and the summary say it (A11Y-01). [stale] values turn every
/// fill grey and carry no severity, because the last reading's may no
/// longer hold (OV-04).
///
/// The legend names each segment with its value; screen readers get one
/// summary instead (A11Y-02), which is not a live region (A11Y-15). The bar
/// does not animate, so reduced motion (A11Y-11) changes nothing.
class StackedBar extends StatelessWidget {
  const StackedBar({
    super.key,
    required this.label,
    required this.segments,
    required this.total,
    required this.unit,
    required this.strings,
    this.thresholds,
    this.stale = false,
    this.showLegend = true,
  });

  /// What the bar measures, as its summary names it.
  final String label;

  /// One to four segments, one per series colour.
  final List<BarSegment> segments;

  /// What the whole bar stands for, in [unit]; null when unknown.
  final double? total;

  final ChartUnit unit;
  final ChartStrings strings;

  /// The levels, in percent of [total], for the first segment.
  final ChartThresholds? thresholds;

  /// Whether the values are the last ones before sampling fell behind.
  final bool stale;

  /// Shows each segment's colour, label and value under the bar. A caller
  /// that shows the figures elsewhere, such as a disk table's columns, can
  /// leave it out; with [thresholds] it must then show the severity in
  /// words beside the bar itself (A11Y-01), because the legend carries the
  /// only visible ones. The summary names it for screen readers either way.
  final bool showLegend;

  static const _barHeight = 8.0;

  @override
  Widget build(BuildContext context) {
    assert(segments.isNotEmpty, 'a stacked bar needs a segment');
    final palette = ChartPalette.of(context);
    assert(segments.length <= palette.series.length, 'a colour per segment');

    final total = _reading(this.total);
    final values = [for (final segment in segments) _reading(segment.value)];
    final thresholds = this.thresholds;
    final primary = values.first;
    final severity =
        stale ||
            thresholds == null ||
            primary == null ||
            total == null ||
            total <= 0
        ? ChartSeverity.normal
        : thresholds.severityOf(primary / total * 100);
    final colours = [
      for (var index = 0; index < segments.length; index++)
        stale
            ? palette.muted
            : (index == 0 ? palette.severityColor(severity) : null) ??
                  palette.series[index],
    ];

    String format(double? value) => value == null
        ? strings.unknownValue
        : formatChartValue(value, unit, strings);
    final parts = [
      for (final (index, segment) in segments.indexed)
        _withSeverity(
          strings.barPart(segment.label, format(values[index])),
          index == 0 ? severity : ChartSeverity.normal,
          strings,
        ),
    ];
    var summary = total == null && values.every((value) => value == null)
        ? strings.seriesUnknown(label)
        : strings.barSummary(
            label,
            parts.join(strings.listSeparator),
            format(total),
          );
    if (stale) summary = strings.stale(summary);

    return Semantics(
      container: true,
      label: summary,
      child: ExcludeSemantics(
        // The fallback width, for a parent that leaves the bar unbounded.
        child: LimitedBox(
          maxWidth: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                spacing: 4,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: _barHeight,
                      child: _bar(
                        palette,
                        cellCount: 1,
                        runs: _stackedRuns(
                          values,
                          total,
                          colours,
                          _fillOf(severity),
                          palette,
                        ),
                      ),
                    ),
                  ),
                  if (thresholds != null) _severitySlot(severity, palette),
                ],
              ),
              if (showLegend)
                _legend(
                  context,
                  palette,
                  parts,
                  values,
                  colours,
                  _fillOf(severity),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The runs of a bar whose segments have [values] out of [total], the
  /// first drawn as [firstFill].
  static List<BarRun> _stackedRuns(
    List<double?> values,
    double? total,
    List<Color> colours,
    BarFill firstFill,
    ChartPalette palette,
  ) {
    BarRun unknownFrom(double start) => (
      cell: 0,
      start: start,
      end: 1,
      color: palette.muted,
      fill: BarFill.unknown,
    );
    if (total == null) return [unknownFrom(0)];

    final runs = <BarRun>[];
    var start = 0.0;
    for (final (index, value) in values.indexed) {
      if (value == null) continue;
      final end = total > 0 ? math.min(1.0, start + value / total) : start;
      if (end > start) {
        runs.add((
          cell: 0,
          start: start,
          end: end,
          color: colours[index],
          fill: index == 0 ? firstFill : BarFill.solid,
        ));
      }
      start = end;
    }
    if (values.contains(null) && start < 1) runs.add(unknownFrom(start));
    return runs;
  }

  Widget _legend(
    BuildContext context,
    ChartPalette palette,
    List<String> parts,
    List<double?> values,
    List<Color> colours,
    BarFill firstFill,
  ) {
    final style = Theme.of(
      context,
    ).textTheme.labelSmall!.copyWith(color: palette.scaleText);
    return Wrap(
      spacing: 12,
      runSpacing: 2,
      children: [
        for (final (index, part) in parts.indexed)
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              // Drawn like its segment, so a severe one keeps its stripe
              // and an unknown one is hatched as the bar's unknown rest is.
              SizedBox.square(
                dimension: 8,
                child: CustomPaint(
                  painter: BarPainter(
                    cellCount: 1,
                    runs: [
                      (
                        cell: 0,
                        start: 0,
                        end: 1,
                        color: values[index] == null
                            ? palette.muted
                            : colours[index],
                        fill: switch (values[index]) {
                          null => BarFill.unknown,
                          _ when index == 0 => firstFill,
                          _ => BarFill.solid,
                        },
                      ),
                    ],
                    trackColor: palette.track,
                  ),
                ),
              ),
              // A long entry wraps rather than overflow a narrow card.
              Flexible(child: Text(part, style: style)),
            ],
          ),
      ],
    );
  }
}

/// A fleet row's pressure bar (03 §10.3, FL-07): one cell per metric
/// (CPU, memory and disk, in that order), each in its fixed series colour
/// and filled to its share.
///
/// Past a threshold a cell takes the severity colour with a stripe of the
/// track through it, so the cell that crossed shows without colour; the
/// slot beside the cells shows the highest severity by an icon's shape,
/// and the tooltip on hover and the summary name each metric with its
/// value and severity (A11Y-01).
/// An unknown share hatches its cell rather than leaving it empty
/// (03 §10.4). [stale] values turn every fill grey and carry no severity
/// (OV-04). Its size stays the same whatever it shows, so fleet rows keep
/// their height and the text beside it does not move.
///
/// Screen readers get the summary (A11Y-02), which is not a live region
/// (A11Y-15). The bar does not animate, so reduced motion (A11Y-11) changes
/// nothing.
class PressureBar extends StatelessWidget {
  const PressureBar({
    super.key,
    required this.cells,
    required this.strings,
    this.stale = false,
  });

  /// One to four metrics, one per series colour.
  final List<PressureCell> cells;

  final ChartStrings strings;

  /// Whether the values are the last ones before sampling fell behind.
  final bool stale;

  static const _barSize = Size(46, 6);

  @override
  Widget build(BuildContext context) {
    assert(cells.isNotEmpty, 'a pressure bar needs a cell');
    final palette = ChartPalette.of(context);
    assert(cells.length <= palette.series.length, 'a colour per cell');

    final percents = [for (final cell in cells) _reading(cell.percent)];
    final severities = [
      for (final cell in cells) _pressureSeverity(cell, stale: stale),
    ];
    final runs = <BarRun>[
      for (final (index, percent) in percents.indexed)
        if (percent == null)
          (
            cell: index,
            start: 0,
            end: 1,
            color: palette.muted,
            fill: BarFill.unknown,
          )
        else if (percent > 0)
          (
            cell: index,
            start: 0,
            end: math.min(1.0, percent / 100),
            color: stale
                ? palette.muted
                : palette.severityColor(severities[index]) ??
                      palette.series[index],
            fill: _fillOf(severities[index]),
          ),
    ];

    final summary = pressureSummary(cells, strings, stale: stale);
    return Semantics(
      container: true,
      label: summary,
      child: Tooltip(
        message: summary,
        excludeFromSemantics: true,
        // Hover only: a touch long-press stays with the row around the bar,
        // where `SidebarRow` opens its menu.
        triggerMode: TooltipTriggerMode.manual,
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              SizedBox.fromSize(
                size: _barSize,
                child: _bar(palette, cellCount: cells.length, runs: runs),
              ),
              if (cells.any((cell) => cell.thresholds != null))
                _severitySlot(
                  severities.reduce((a, b) => a.index >= b.index ? a : b),
                  palette,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The summary a [PressureBar] of [cells] gives screen readers and its
/// tooltip (A11Y-02): each metric with its value and any severity, marked
/// stale while [stale]. A host that folds the bar into a larger node, such
/// as a fleet row's label, says this and excludes the bar's own.
String pressureSummary(
  List<PressureCell> cells,
  ChartStrings strings, {
  bool stale = false,
}) {
  final parts = [
    for (final cell in cells)
      _withSeverity(
        strings.barPart(cell.label, switch (_reading(cell.percent)) {
          null => strings.unknownValue,
          final percent => strings.percent(percent),
        }),
        _pressureSeverity(cell, stale: stale),
        strings,
      ),
  ];
  final summary = parts.join(strings.listSeparator);
  return stale ? strings.stale(summary) : summary;
}

/// How far [cell] has crossed its thresholds; a stale or unknown value
/// carries no severity.
ChartSeverity _pressureSeverity(PressureCell cell, {required bool stale}) {
  final percent = _reading(cell.percent);
  final thresholds = cell.thresholds;
  if (stale || thresholds == null || percent == null) {
    return ChartSeverity.normal;
  }
  return thresholds.severityOf(percent);
}

/// A value the bars can draw: null, negative or not finite is no reading,
/// shown as unknown rather than as zero (03 §10.4).
double? _reading(double? value) =>
    value != null && value.isFinite && value >= 0 ? value : null;

/// A severe fill carries a stripe as well as its colour: the warning and
/// critical tints are not held apart from the series tints under
/// colour-vision deficiencies (light amber and orange nearly meet under
/// deuteranopia), so the stripe shows which part crossed (A11Y-01).
BarFill _fillOf(ChartSeverity severity) =>
    severity.alarms ? BarFill.severe : BarFill.solid;

String _withSeverity(
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

const _severityIconSize = 14.0;

/// The icon beside a bar that shows its severity by shape as well as
/// colour (A11Y-01): a triangle for warning, a circle for critical. The
/// slot keeps its size when empty, so the bar never changes length.
Widget _severitySlot(ChartSeverity severity, ChartPalette palette) =>
    SizedBox.square(
      dimension: _severityIconSize,
      child: switch (severity) {
        ChartSeverity.normal => null,
        ChartSeverity.careful => Icon(
          Icons.info_rounded,
          size: _severityIconSize,
          color: palette.scaleText,
        ),
        ChartSeverity.warning => Icon(
          Icons.warning_rounded,
          size: _severityIconSize,
          color: palette.warning,
        ),
        ChartSeverity.critical => Icon(
          Icons.error_rounded,
          size: _severityIconSize,
          color: palette.critical,
        ),
      },
    );

Widget _bar(
  ChartPalette palette, {
  required int cellCount,
  required List<BarRun> runs,
}) => RepaintBoundary(
  child: CustomPaint(
    size: Size.infinite,
    painter: BarPainter(
      cellCount: cellCount,
      runs: runs,
      trackColor: palette.track,
    ),
  ),
);

/// A stretch of one bar cell, from [start] to [end] as shares of the
/// cell's width, drawn in [color] as [fill] says. A cell's runs come in
/// order, and one that starts past the cell's left edge starts where the
/// run before it ends.
typedef BarRun = ({
  int cell,
  double start,
  double end,
  Color color,
  BarFill fill,
});

/// How a [BarRun] draws its colour.
enum BarFill {
  /// Filled.
  solid,

  /// Filled, with a stripe of the track through the middle: a value past
  /// a threshold.
  severe,

  /// Hatched: a value the host did not report.
  unknown,
}

/// Paints a [StackedBar]'s or a [PressureBar]'s cells; visible so painter
/// tests can check what it draws, and kept out of the charts' barrel.
///
/// The bars take values rather than a ring, so the painter repaints when
/// its runs change instead of on a version counter.
@visibleForTesting
final class BarPainter extends CustomPainter {
  BarPainter({
    required this.cellCount,
    required this.runs,
    required this.trackColor,
  }) : assert(cellCount > 0, 'a bar has a cell');

  final int cellCount;
  final List<BarRun> runs;
  final Color trackColor;

  static const _cellGap = 2.0;

  /// The track shows through this gap between neighbouring runs, so the
  /// segments part by more than colour, also when stale turns them grey.
  /// The run after the gap gives up the width, at most half its own, so a
  /// run narrower than the gap keeps a sliver rather than vanishing; a run
  /// that ends inside its cell is not shortened, so a small value still
  /// shows.
  static const runGap = 1.0;

  static const _hatchSpacing = 4.0;
  static const hatchWidth = 1.0;

  /// The height of a [BarFill.severe] run's stripe.
  static const severeStripe = 2.0;

  static const _cornerRadius = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = (size.width - _cellGap * (cellCount - 1)) / cellCount;
    if (cellWidth <= 0 || size.height <= 0) return;
    final radius = Radius.circular(math.min(_cornerRadius, size.height / 2));
    final track = Paint()..color = trackColor;

    for (var cell = 0; cell < cellCount; cell++) {
      final rect = Rect.fromLTWH(
        cell * (cellWidth + _cellGap),
        0,
        cellWidth,
        size.height,
      );
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
      canvas.drawRect(rect, track);
      for (final run in runs) {
        if (run.cell != cell) continue;
        final start = run.start.clamp(0.0, 1.0);
        final end = run.end.clamp(0.0, 1.0);
        final runWidth = (end - start) * rect.width;
        final gap = start > 0 ? math.min(runGap, runWidth / 2) : 0.0;
        final left = rect.left + start * rect.width + gap;
        final right = rect.left + end * rect.width;
        if (right <= left) continue;
        final runRect = Rect.fromLTRB(left, rect.top, right, rect.bottom);
        switch (run.fill) {
          case BarFill.solid:
            canvas.drawRect(runRect, Paint()..color = run.color);
          case BarFill.severe:
            canvas.drawRect(runRect, Paint()..color = run.color);
            canvas.drawRect(
              Rect.fromCenter(
                center: runRect.center,
                width: runRect.width,
                height: severeStripe,
              ),
              track,
            );
          case BarFill.unknown:
            _hatch(canvas, runRect, run.color);
        }
      }
      canvas.restore();
    }
  }

  /// Rising diagonals across [rect], a pattern that reads as "unknown"
  /// without relying on colour.
  void _hatch(Canvas canvas, Rect rect, Color color) {
    final lines = Path();
    for (var x = rect.left - rect.height; x < rect.right; x += _hatchSpacing) {
      lines
        ..moveTo(x, rect.bottom)
        ..lineTo(x + rect.height, rect.top);
    }
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawPath(
      lines,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = hatchWidth,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(BarPainter oldDelegate) =>
      oldDelegate.cellCount != cellCount ||
      oldDelegate.trackColor != trackColor ||
      !listEquals(oldDelegate.runs, runs);
}

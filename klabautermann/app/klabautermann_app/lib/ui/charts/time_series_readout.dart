import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_marks.dart';
import 'time_series_crosshair.dart';
import 'time_series_painter.dart';

/// A series' legend swatch: a stroke of its line with its marker on it.
final class LaneSwatch extends CustomPainter {
  LaneSwatch(this.color, this.marker, {this.line = true});

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
  bool shouldRepaint(LaneSwatch oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.marker != marker ||
      oldDelegate.line != line;
}

final class HatchSwatch extends CustomPainter {
  HatchSwatch(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) =>
      paintHatch(canvas, Offset.zero & size, ink);

  @override
  bool shouldRepaint(HatchSwatch oldDelegate) => oldDelegate.ink != ink;
}

/// The crosshair's readout: the time, then each series' shape with its
/// label and value, or inside a gap that there is no reading and why. It
/// wraps at the width it is given and scales down rather than overflow a
/// short plot under large text. Screen readers hear it through the
/// chart's adjustable readout node instead.
class Readout extends StatelessWidget {
  const Readout({
    super.key,
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
                    painter: LaneSwatch(
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
                    painter: HatchSwatch(ink),
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
final class ReadoutLayout extends SingleChildLayoutDelegate {
  ReadoutLayout({required this.x, required this.top, required this.minSide});

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
  bool shouldRelayout(ReadoutLayout oldDelegate) =>
      oldDelegate.x != x ||
      oldDelegate.top != top ||
      oldDelegate.minSide != minSide;
}

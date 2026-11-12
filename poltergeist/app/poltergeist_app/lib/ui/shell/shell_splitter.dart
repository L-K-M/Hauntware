import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The width of a region boundary's grab area: a 1 px visible line with
/// a few pixels of transparent hit area either side, so the boundary
/// reads as a hairline (ForkLift/Finder) while the pointer target stays
/// usable. Stage budgets still count it in full.
const shellSplitterExtent = 7.0;

/// The width a region boundary takes in layout: the visible hairline and
/// nothing more, so the regions' own borders run into it. The
/// [shellSplitterExtent]-wide grab area floats over it ([ShellSeam]).
const shellSeamWidth = 1.0;

/// A region boundary as it takes part in layout: [shellSeamWidth] of
/// hairline, full height, so the borders of the regions either side (the
/// header divider, a pane's active-side accent) run right up to it instead
/// of stopping at the edge of a wider splitter slot.
class ShellSeam extends StatelessWidget {
  const ShellSeam({super.key, this.color});

  /// Defaults to the chrome separator the shell's other hairlines use.
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: shellSeamWidth,
    height: double.infinity,
    child: ColoredBox(
      color: color ??
          PoltergeistChrome.of(context, poltergeistThemeStyle).separator,
    ),
  );

  /// Floats [handle], [extent] wide, centred over the seam in [row] that
  /// begins [start] pixels from its start edge (or finishes [end] pixels
  /// from its end edge), so the grab area overlaps the regions either
  /// side instead of pushing them apart. Give exactly one of the two.
  static Widget straddle(
    Widget row, {
    required Widget handle,
    double? start,
    double? end,
    double extent = shellSplitterExtent,
  }) {
    assert((start == null) != (end == null));
    final overhang = (extent - shellSeamWidth) / 2;
    return Stack(
      children: [
        Positioned.fill(child: row),
        PositionedDirectional(
          start: start == null ? null : start - overhang,
          end: end == null ? null : end - overhang,
          top: 0,
          bottom: 0,
          width: extent,
          child: handle,
        ),
      ],
    );
  }
}

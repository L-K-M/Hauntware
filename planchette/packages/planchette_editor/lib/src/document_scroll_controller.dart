import 'package:flutter/widgets.dart';

/// The document field's scroll controller. When the view remounts the field
/// it hands the current offset to the field's next scroll position, which
/// then starts there: the first frame of the new field draws in place
/// instead of at the top.
class DocumentScrollController extends ScrollController {
  double? _carried;

  /// Has the next position this controller creates start at the current
  /// offset. Call it just before the field is replaced.
  void carryOffsetOver() {
    if (positions.length != 1) return;
    _carried = positions.single.pixels;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final carried = _carried;
    _carried = null;
    return ScrollPositionWithSingleContext(
      physics: physics,
      context: context,
      initialPixels: carried ?? initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show nearEqual;

/// How far from the newest line still counts as at it, in logical pixels.
const double endTolerance = 1;

/// A scroll controller whose position stays on the newest line while
/// [_following] says so: when the content or the viewport changes, the
/// position moves to the end during layout, in the same frame, without a
/// scroll notification.
final class TailScrollController extends ScrollController {
  TailScrollController(this._following) : super(keepScrollOffset: false);

  final bool Function() _following;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => TailScrollPosition(
    _following,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

final class TailScrollPosition extends ScrollPositionWithSingleContext {
  TailScrollPosition(
    this._following, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final bool Function() _following;

  /// Moves the offset by [delta] as a layout correction does and lays out
  /// again. A drag carries on from the new offset; a fling, whose
  /// simulation sets absolute offsets, starts again from it at its current
  /// velocity; an animation, which also sets absolute offsets, moves the
  /// rest of its path with the lines ([_ShiftableScrollAnimation]) by
  /// [path], or by [delta] when it is null. [path] differs from [delta]
  /// when the offset cannot move as far as the lines did. Sends no scroll
  /// notification: the user did not scroll.
  void shiftBy(double delta, {double? path}) {
    correctBy(delta);
    final current = activity;
    if (current is BallisticScrollActivity) goBallistic(current.velocity);
    if (current is _ShiftableScrollAnimation) {
      current.shiftBy(delta, path: path ?? delta);
    }
    notifyListeners();
  }

  /// Animates as the inherited animateTo does, but with an animation that
  /// [shiftBy] can move. The desktop scrollbar's track click animates this
  /// way.
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (nearEqual(to, pixels, physics.toleranceFor(this).distance)) {
      jumpTo(to);
      return Future<void>.value();
    }

    final animation = _ShiftableScrollAnimation(
      this,
      from: pixels,
      to: to,
      toEnd: hasContentDimensions && to > maxScrollExtent - endTolerance,
      duration: duration,
      curve: curve,
      vsync: context.vsync,
    );
    beginActivity(animation);
    return animation.done;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // Content that shrank under an idle offset (wrapped rows after a wider
    // layout, a long line leaving) moves the offset to the new end at once,
    // following or not. The physics would leave an offset that a layout
    // correction moved past the end and then spring back, and the scroll
    // updates of that spring would resume following. Past the end during a
    // gesture or fling is a bounce, left to the physics.
    final shrank =
        pixels > maxScrollExtent && !(activity?.isScrolling ?? false);
    if (shrank) correctPixels(maxScrollExtent);
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (!shrank && (!_following() || pixels >= maxScrollExtent)) {
      return accepted;
    }

    correctPixels(maxScrollExtent);
    // The viewport laid out its children for the old offset: lay out again.
    return false;
  }
}

/// A scroll animation whose path moves with the lines when old lines leave
/// the buffer during it, so it ends on the line it was aimed at (the
/// oldest line left, if that one left too), or on the newest line when it
/// was aimed at the end, without a jump on the way.
///
/// A plain [DrivenScrollActivity] sets the offsets of its own path each
/// frame, which would undo the shift and land the view off its target by
/// as many lines as left. Restarting the animation instead would start its
/// curve and duration again on every batch.
final class _ShiftableScrollAnimation extends DrivenScrollActivity {
  _ShiftableScrollAnimation(
    super.delegate, {
    required super.from,
    required super.to,
    required this._toEnd,
    required super.duration,
    required super.curve,
    required super.vsync,
  }) : _to = to,
       _value = from;

  /// The animation's target, in the offsets it started with.
  final double _to;

  /// Whether it was aimed at the newest line, which stays at the end as
  /// lines leave instead of moving with them.
  final bool _toEnd;

  /// The animation's latest value, in the offsets it started with.
  double _value;

  /// How far the whole path is moved when it ends on a line.
  double _targetShift = 0;

  /// The shifts of a path that ends at the newest line, each with how far
  /// the value was from [_to] when it came.
  final _endShifts = <({double left, double delta})>[];

  /// Moves the rest of the path with the lines. When it ends on a line,
  /// all of it moves by [path], how far the lines moved, even where the
  /// offset could not follow them all the way ([delta]). When it ends at
  /// the newest line, it moves by [delta] where it is now, the shift the
  /// offset just took, and less on the way to none at the end.
  void shiftBy(double delta, {required double path}) {
    if (!_toEnd) {
      _targetShift += path;
      return;
    }

    final left = _to - _value;
    // At its end already: the next frame sets the end, as it should.
    if (left.abs() < precisionErrorTolerance) return;
    _endShifts.add((left: left, delta: delta));
  }

  @override
  bool applyMoveTo(double value) {
    _value = value;
    // An end shift fades in proportion to the distance left. A curve that
    // turns back from the end or runs past it would scale the shift up or
    // reverse it, so it never takes more than all of it, nor any past the
    // end.
    var shift = _targetShift;
    for (final (:left, :delta) in _endShifts) {
      shift += delta * ((_to - value) / left).clamp(0.0, 1.0);
    }
    // When the lines in sight left, the moved path runs above the oldest
    // line left, and when the line aimed at left too, so does its end.
    // Bouncing physics would show the blank space there, and clamping
    // physics would report overscroll, which ends the animation on the
    // oldest line, so the path goes no further above the oldest line than
    // its curve does.
    final minExtent = (delegate as ScrollPosition).minScrollExtent;
    return super.applyMoveTo(
      math.max(value + shift, math.min(value, minExtent)),
    );
  }
}

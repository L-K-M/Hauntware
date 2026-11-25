import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        ItemExtentBuilder,
        RenderSliverFixedExtentBoxAdaptor,
        SliverConstraints,
        SliverGeometry,
        SliverLayoutDimensions;

import 'log_row_counts.dart';

/// The rows of a [LogView]: a sliver like `SliverVariedExtentList` whose
/// offsets and indexes come from [RowCounts] in O(log n), where that
/// list sums every extent before an index, and which measures the entries
/// a layout shows before laying them out.
final class LogRows extends SliverMultiBoxAdaptorWidget {
  const LogRows({
    super.key,
    required super.delegate,
    required this.rows,
    required this.revision,
    required this.lineHeight,
  });

  final RowCounts rows;

  /// [rows]' revision when built: a new one lays the sliver out again.
  final int revision;
  final double lineHeight;

  @override
  RenderLogRows createRenderObject(BuildContext context) => RenderLogRows(
    childManager: context as SliverMultiBoxAdaptorElement,
    rows: rows,
    revision: revision,
    lineHeight: lineHeight,
  );

  @override
  void updateRenderObject(BuildContext context, RenderLogRows renderObject) {
    renderObject
      ..rows = rows
      ..revision = revision
      ..lineHeight = lineHeight;
  }
}

final class RenderLogRows extends RenderSliverFixedExtentBoxAdaptor {
  RenderLogRows({
    required super.childManager,
    required this._rows,
    required this._revision,
    required this._lineHeight,
  });

  RowCounts _rows;
  set rows(RowCounts value) {
    if (identical(value, _rows)) return;
    _rows = value;
    markNeedsLayout();
  }

  int _revision;
  set revision(int value) {
    if (value == _revision) return;
    _revision = value;
    markNeedsLayout();
  }

  double _lineHeight;
  set lineHeight(double value) {
    if (value == _lineHeight) return;
    _lineHeight = value;
    markNeedsLayout();
  }

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder get itemExtentBuilder => _extentOf;

  double? _extentOf(int index, SliverLayoutDimensions dimensions) =>
      index < _rows.length ? _rows.rowsOf(index) * _lineHeight : null;

  /// The row [offset] falls in, an offset on a boundary taking the row
  /// after it, as the fixed-extent list rounds.
  int _rowAt(double offset) {
    final rows = offset / _lineHeight;
    final nearest = rows.round();
    if ((rows - nearest).abs() * _lineHeight < precisionErrorTolerance) {
      return nearest;
    }
    return rows.floor();
  }

  /// The last row before [offset].
  int _rowBefore(double offset) {
    final rows = offset / _lineHeight - 1;
    final nearest = rows.round();
    if ((rows - nearest).abs() * _lineHeight < precisionErrorTolerance) {
      return math.max(0, nearest);
    }
    return math.max(0, rows.ceil());
  }

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _rows.rowsBefore(math.min(index, _rows.length)) * _lineHeight;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _rows.indexAtRow(_rowAt(scrollOffset));

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _rows.indexAtRow(_rowBefore(scrollOffset));

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _rows.total * _lineHeight;

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _rows.total * _lineHeight;

  @override
  void performLayout() {
    final constraints = this.constraints;
    final top = constraints.scrollOffset + constraints.cacheOrigin;
    final correction = _rows.measure(
      top / _lineHeight,
      constraints.scrollOffset / _lineHeight,
      (top + constraints.remainingCacheExtent) / _lineHeight,
      constraints.crossAxisExtent,
    );
    if (correction != 0) {
      geometry = SliverGeometry(
        scrollOffsetCorrection: correction * _lineHeight,
      );
      return;
    }
    super.performLayout();
  }
}

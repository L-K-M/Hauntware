import 'dart:math' as math;
import 'dart:typed_data';

import 'log_view_controller.dart';

/// The slots a [RowCounts] starts with.
const int _minRowSlots = 1024;

/// How close to a row boundary a scroll offset counts as on it, in rows.
const double rowTolerance = 1e-6;

/// The row count of every entry a [LogView] holds, with the rows before
/// any entry found in O(log n) through a Fenwick tree, so a frame costs
/// the same however many lines are held (03 §11.4).
///
/// Only the entries a layout shows, and as many rows above its offset, are
/// measured, once per width, font and locale ([measure]); the others keep
/// the count of their last measurement or, before one, an estimate. A
/// width change therefore lays out only the lines near the view. When
/// measuring an entry above the scroll offset changes its count, the
/// layout moves the offset by the difference, and the offset keeps its
/// share of the entry it is in to within a row ([_keepShare]), so the
/// lines in sight hold still.
final class RowCounts {
  RowCounts(this._measure, this._estimate);

  /// The exact rows of the entry at an index in a row of a cross-axis
  /// extent.
  final int Function(int index, double crossAxisExtent) _measure;

  /// A guess at the rows of the entry at an index until a layout measures
  /// it, from the cross-axis extent last measured at, if any.
  final int Function(int index, double? crossAxisExtent) _estimate;

  // Entry i lives in slot _front + i; the slots before _front belong to
  // evicted entries, whose rows _frontRows cancels. _tree is the Fenwick
  // tree over _counts, 1-based.
  var _counts = Int32List(_minRowSlots);
  var _measuredIn = Int32List(_minRowSlots);
  var _tree = Int32List(_minRowSlots + 1);
  int _front = 0;
  int _frontRows = 0;
  int _length = 0;
  int _total = 0;
  int _firstSeq = 0;

  /// Counts measured in an older generation are estimates; 0 is never.
  int _generation = 1;

  /// The cross-axis extent last measured at, or null before a layout.
  double? _crossAxisExtent;

  /// Changes whenever the rows would lay out differently, so the sliver
  /// lays out again even when the entry count stays the same.
  int get revision => _revision;
  int _revision = 0;

  int get length => _length;

  /// The rows of every held entry.
  int get total => _total;

  int rowsOf(int index) => _counts[_front + index];

  int rowsBefore(int index) => _prefix(_front + index) - _frontRows;

  /// The entry holding [row], clamped to the held entries.
  int indexAtRow(int row) {
    if (_length == 0 || row <= 0) return 0;

    // The most slots whose rows end at or before row: the next one holds
    // it.
    var rest = row + _frontRows;
    var slots = 0;
    for (var step = 1 << (_counts.length.bitLength - 1); step > 0; step >>= 1) {
      final next = slots + step;
      if (next <= _counts.length && _tree[next] <= rest) {
        slots = next;
        rest -= _tree[next];
      }
    }
    return (slots - _front).clamp(0, _length - 1);
  }

  /// Brings the counts in step with [controller], guessing new entries'
  /// rows, and returns the entries that left from the front and their
  /// rows.
  ({int entries, int rows}) sync(LogViewController controller) {
    var entries = 0;
    var rows = 0;
    while (_length > 0 && _firstSeq < controller.firstSeq) {
      final gone = _counts[_front++];
      _frontRows += gone;
      _total -= gone;
      _length--;
      _firstSeq++;
      entries++;
      rows += gone;
    }
    if (_length == 0) _firstSeq = controller.firstSeq;

    final end = controller.firstSeq + controller.length;
    for (var seq = _firstSeq + _length; seq < end; seq++) {
      _append(_estimate(seq - controller.firstSeq, _crossAxisExtent));
    }
    _revision++;
    return (entries: entries, rows: rows);
  }

  /// Measures the entry at [index] again at once, for a change only it
  /// sees, such as its fields showing, and returns how its count changed.
  /// Before a layout gives the counts a width, it estimates the entry.
  int remeasure(int index) {
    final slot = _front + index;
    _measuredIn[slot] = 0;
    final change = _crossAxisExtent == null
        ? _recount(slot, _estimate(index, null))
        : _measureAt(index);
    _revision++;
    return change;
  }

  /// Makes every count an estimate, for a new font, scale, locale or
  /// gutter.
  void invalidate() {
    _generation++;
    _revision++;
  }

  /// Measures the entries a layout of rows [top] to [bottom] shows, with
  /// its scroll offset at row [anchor], and as many rows above that
  /// offset, and returns the rows to move the offset by so the entry at it
  /// stays there and the offset keeps its share of it to within a row.
  int measure(
    double top,
    double anchor,
    double bottom,
    double crossAxisExtent,
  ) {
    if (crossAxisExtent != _crossAxisExtent) {
      _crossAxisExtent = crossAxisExtent;
      _generation++;
    }
    if (_length == 0) return 0;

    // A layout that reaches the newest entry may be a following view's,
    // which then moves to the new end. Measuring the rows the end shows
    // now keeps that to one more pass; otherwise every screenful the
    // counts grew by would cost one, past the viewport's limit of ten.
    final reachesEnd = bottom >= _total;

    // Below the entry at the offset, a new count moves nothing above; above
    // it, every change moves the offset by as much, and the offset keeps
    // its share of that entry's own rows to within a row.
    final first = indexAtRow((anchor + rowTolerance).floor());
    final firstRow = rowsBefore(first);
    var end = firstRow;
    var firstChange = 0;
    for (var i = first; i < _length && end < bottom; i++) {
      final change = _measureAt(i);
      if (i == first) firstChange = change;
      end += rowsOf(i);
    }

    var correction = _keepShare(anchor - firstRow, rowsOf(first), firstChange);
    if (reachesEnd) {
      var tail = 0;
      for (var i = _length - 1; i >= 0 && tail < bottom - top; i--) {
        final change = _measureAt(i);
        if (i < first) correction += change;
        tail += rowsOf(i);
      }
    }
    // Above the offset, as many rows as the layout spans, though its cache
    // reaches less far: a page up from here then lands on measured rows,
    // and their counts below the new offset cannot push lines not yet seen
    // out past the view.
    var above = anchor - firstRow;
    for (var i = first - 1; i >= 0 && above < bottom - top; i--) {
      correction += _measureAt(i);
      above += rowsOf(i);
    }
    return correction;
  }

  /// The whole rows to move an offset [into] rows into an entry by when
  /// the entry's count changed by [change] to [rows], so the offset keeps
  /// its share of the entry to within a row: it keeps its place in its
  /// row and moves to the row of the entry nearest its old share, so an
  /// offset at the entry's start stays there. Kept as many rows in, the
  /// offset would land past the end of an entry that a wider row shrank,
  /// and the lines in sight below would scroll away unseen; an entry that
  /// grew would push them out of the view instead.
  static int _keepShare(double into, int rows, int change) {
    final before = rows - change;
    final row = (into + rowTolerance).floor();
    // An offset past the last entry, as in an overscroll, has no share.
    if (change == 0 || row < 0 || row >= before) return 0;
    final target = (into * rows / before - (into - row)).round();
    return target.clamp(0, rows - 1) - row;
  }

  /// Measures the entry at [index] unless this generation did, and returns
  /// how its count changed.
  int _measureAt(int index) {
    final slot = _front + index;
    if (_measuredIn[slot] == _generation) return 0;

    _measuredIn[slot] = _generation;
    return _recount(slot, _measure(index, _crossAxisExtent!));
  }

  /// Sets the count in [slot] to [rows] and returns how it changed.
  int _recount(int slot, int rows) {
    final change = rows - _counts[slot];
    if (change != 0) {
      _counts[slot] = rows;
      _total += change;
      _add(slot, change);
    }
    return change;
  }

  void _append(int rows) {
    if (_front + _length == _counts.length) _compact();
    final slot = _front + _length++;
    _counts[slot] = rows;
    _measuredIn[slot] = 0;
    _total += rows;
    _add(slot, rows);
  }

  /// Moves the held entries to the start of new slots, twice as many as
  /// they need, so moving costs O(1) a line over time.
  void _compact() {
    final size = math.max(_minRowSlots, 2 * (_length + 1));
    _counts = Int32List(size)..setRange(0, _length, _counts, _front);
    _measuredIn = Int32List(size)..setRange(0, _length, _measuredIn, _front);
    _tree = Int32List(size + 1);
    for (var k = 1; k <= size; k++) {
      _tree[k] += _counts[k - 1];
      final parent = k + (k & -k);
      if (parent <= size) _tree[parent] += _tree[k];
    }
    _front = 0;
    _frontRows = 0;
  }

  void _add(int slot, int change) {
    for (var k = slot + 1; k < _tree.length; k += k & -k) {
      _tree[k] += change;
    }
  }

  /// The rows of slots 0 to [slots] - 1.
  int _prefix(int slots) {
    var sum = 0;
    for (var k = slots; k > 0; k -= k & -k) {
      sum += _tree[k];
    }
    return sum;
  }
}

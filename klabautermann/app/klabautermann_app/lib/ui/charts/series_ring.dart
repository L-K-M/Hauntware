import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A fixed-capacity ring of samples behind one chart series (03 §10.7): the
/// newest [capacity] values in arrival order, with null for a sample that
/// is unknown (a missed tick, a value the host could not report, or one
/// that is not finite), which charts draw as a gap and never as zero
/// (03 §10.4).
///
/// Each sample bumps [version] and notifies listeners, so a chart repaints
/// on a new version rather than comparing samples.
final class SeriesRing extends ChangeNotifier {
  SeriesRing(this.capacity)
    : assert(capacity > 1, 'a series needs two slots to draw a line'),
      _slots = Float64List(capacity + 1);

  final int capacity;

  /// NaN marks an unknown sample, so the ring stays one unboxed buffer. Its
  /// one slot past [capacity] holds the sample the last [add] pushed out.
  final Float64List _slots;
  int _added = 0;

  /// The samples, oldest first: a live, read-only view.
  late final List<double?> samples = _RingView(this, capacity);

  /// [samples] behind the one the last [add] pushed out of a full ring, so
  /// a chart can slide it out of view: a live, read-only view whose first
  /// entry has running index [added] minus its length.
  late final List<double?> samplesWithEvicted = _RingView(this, capacity + 1);

  /// Bumped by every sample.
  int get version => _added;

  int get length => math.min(_added, capacity);

  /// How many samples were ever added: the running index the next one
  /// takes. Charts align their downsampling columns to running indices.
  int get added => _added;

  /// The running index of [samples]' first entry.
  int get firstIndex => _added - length;

  void add(double? value) {
    _slots[_added % _slots.length] = value != null && value.isFinite
        ? value
        : double.nan;
    _added++;
    notifyListeners();
  }

  double? _at(int runningIndex) {
    final value = _slots[runningIndex % _slots.length];
    return value.isNaN ? null : value;
  }
}

/// [SeriesRing.samples] and [SeriesRing.samplesWithEvicted]: the newest
/// [_window] samples.
final class _RingView extends ListBase<double?> {
  _RingView(this._ring, this._window);

  final SeriesRing _ring;
  final int _window;

  @override
  int get length => math.min(_ring._added, _window);

  @override
  set length(int _) => throw UnsupportedError(_readOnly);

  @override
  double? operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return _ring._at(_ring._added - length + index);
  }

  @override
  void operator []=(int index, double? value) =>
      throw UnsupportedError(_readOnly);

  static const _readOnly = 'A series ring changes only through add';
}

/// One column of a downsampled series: the extremes of its known samples in
/// the order they arrived ([first] then [second]; equal when the column
/// holds one known value), and the running index of its first slot.
typedef MinMaxColumn = ({int start, double first, double second});

/// Min-max downsampling to the pixel width (03 §10.7): [samples] whose first
/// entry has running index [firstIndex], cut into columns of [bucketSize]
/// slots aligned to running indices, so a column keeps the same samples as
/// new ones arrive and the line does not shimmer while it scrolls.
///
/// Each column keeps its lowest and highest known value, so a spike
/// narrower than a pixel still shows. A column with no known sample is
/// null, which a chart draws as a gap; a gap narrower than one column gives
/// way to its neighbours' values in that column.
List<MinMaxColumn?> downsampleMinMax(
  List<double?> samples, {
  required int bucketSize,
  int firstIndex = 0,
}) {
  assert(bucketSize > 0, 'a column holds at least one sample');
  final end = firstIndex + samples.length;
  double? at(int index) => samples[index - firstIndex];

  final columns = <MinMaxColumn?>[];
  var start = firstIndex - firstIndex % bucketSize;
  for (; start < end; start += bucketSize) {
    int? lowAt, highAt;
    final stop = math.min(start + bucketSize, end);
    for (var index = math.max(start, firstIndex); index < stop; index++) {
      final value = at(index);
      if (value == null) continue;
      if (lowAt == null || value < at(lowAt)!) lowAt = index;
      if (highAt == null || value > at(highAt)!) highAt = index;
    }
    if (lowAt == null || highAt == null) {
      columns.add(null);
      continue;
    }
    final (first, second) = lowAt <= highAt ? (lowAt, highAt) : (highAt, lowAt);
    columns.add((start: start, first: at(first)!, second: at(second)!));
  }
  return columns;
}

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The most series one time-series chart draws (03 §10.7).
const _maxLanes = 4;

/// Why a chart has no data for a while (03 §9.5 item 5).
enum ChartGapReason {
  /// The app was not running.
  appClosed,

  /// The app was in the background, where it stops sampling (D34).
  background,

  /// The link to the server was down.
  disconnected,
}

/// A period without data, drawn as a hatched band labelled with its
/// reason. [end] is null while the gap lasts.
typedef ChartGap = ({DateTime start, DateTime? end, ChartGapReason reason});

/// A fixed-capacity ring of timed samples behind a time-series chart
/// (03 §10.7): the newest [capacity] ticks, each with one value per lane
/// (null when unknown, as in `SeriesRing`), and the gaps between them.
///
/// The caller opens a gap when sampling stops ([openGap]); the next sample
/// closes it, and a chart never joins that sample to the one before.
/// Times must not go backwards: one earlier than the newest time the ring
/// holds is raised to it, so the ring stays ordered when the wall clock is
/// set back.
///
/// Each change bumps [version] and notifies listeners.
final class TimeSeriesRing extends ChangeNotifier {
  TimeSeriesRing({required this.capacity, required this.lanes})
    : assert(capacity > 1, 'a series needs two slots to draw a line'),
      assert(
        lanes >= 1 && lanes <= _maxLanes,
        'a chart draws 1 to $_maxLanes series',
      ),
      _times = Int64List(capacity),
      _values = Float64List(capacity * lanes),
      _joined = Uint8List(capacity);

  final int capacity;
  final int lanes;

  /// Microseconds since the epoch per slot.
  final Int64List _times;

  /// [lanes] values per slot, NaN for an unknown one.
  final Float64List _values;

  /// 1 where a slot's sample continues the line from the one before it.
  final Uint8List _joined;

  final List<ChartGap> _gaps = [];
  int _added = 0;
  int _version = 0;
  int _latest = 0;

  /// The time of the newest sample the ring has dropped, in microseconds
  /// since the epoch, or null while it has dropped none.
  int? _evicted;

  /// Bumped by every sample and gap change.
  int get version => _version;

  int get length => math.min(_added, capacity);

  /// The gaps, oldest first; the last one may still be open. A gap is
  /// dropped once a sample at or after its end has left the ring, so the
  /// gaps that lead up to the oldest sample stay.
  late final List<ChartGap> gaps = UnmodifiableListView(_gaps);

  /// Sample [index]'s time in microseconds since the epoch, oldest first.
  int microsAt(int index) => _times[_slot(index)];

  /// Sample [index]'s value in [lane], or null when unknown.
  double? valueAt(int lane, int index) {
    final value = _values[_slot(index) * lanes + lane];
    return value.isNaN ? null : value;
  }

  /// Whether sample [index] continues the line from the one before: false
  /// for the oldest sample and for the first sample after a gap.
  bool joinsPrevious(int index) => index > 0 && _joined[_slot(index)] == 1;

  /// The index of the first sample at or after [micros], or [length].
  int indexAtOrAfter(int micros) {
    var low = 0, high = length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (microsAt(middle) < micros) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Adds one tick at [at] with a value per lane, closing an open gap.
  void add(DateTime at, List<double?> values) {
    assert(values.length == lanes, 'one value per lane');
    final micros = _ordered(at);
    final slot = _added % capacity;
    if (_added >= capacity) _evicted = _times[slot];
    _times[slot] = micros;
    for (var lane = 0; lane < lanes; lane++) {
      final value = values[lane];
      _values[slot * lanes + lane] = value != null && value.isFinite
          ? value
          : double.nan;
    }
    final open = _openGap;
    if (open != null) {
      _gaps.last = (start: open.start, end: _time(micros), reason: open.reason);
    }
    _joined[slot] = _added > 0 && open == null ? 1 : 0;
    _added++;
    _changed();
  }

  /// Records that sampling stopped at [at] for [reason]. An open gap with
  /// another reason ends there; one with the same reason continues.
  void openGap(DateTime at, ChartGapReason reason) {
    final open = _openGap;
    if (open?.reason == reason) return;
    final micros = _ordered(at);
    if (open != null) {
      _gaps.last = (start: open.start, end: _time(micros), reason: open.reason);
    }
    _gaps.add((start: _time(micros), end: null, reason: reason));
    _changed();
  }

  ChartGap? get _openGap {
    final last = _gaps.lastOrNull;
    return last != null && last.end == null ? last : null;
  }

  int _slot(int index) {
    RangeError.checkValidIndex(index, null, 'index', length);
    return (_added - length + index) % capacity;
  }

  int _ordered(DateTime at) =>
      _latest = math.max(_latest, at.microsecondsSinceEpoch);

  DateTime _time(int micros) => DateTime.fromMicrosecondsSinceEpoch(micros);

  void _changed() {
    // A gap is out of the data once a sample at or after its end has left
    // the ring. Until then it names time before the oldest sample, as when
    // sampling stopped, perhaps for several reasons in turn, before the
    // first sample arrived. The cap bounds gaps opened while no sample
    // arrives.
    final evicted = _evicted;
    if (evicted != null) {
      _gaps.removeWhere(
        (gap) => gap.end != null && gap.end!.microsecondsSinceEpoch <= evicted,
      );
    }
    if (_gaps.length > capacity) _gaps.removeRange(0, _gaps.length - capacity);
    _version++;
    notifyListeners();
  }
}

/// The samples of [lane] that a chart draws between [from] and [to]
/// microseconds, as runs of sample indices: each run is one line, and no
/// run spans an unknown sample or a gap, so nothing is interpolated across
/// either. A run of one sample is a dot.
///
/// Within a run, columns of [bucket] microseconds aligned to the epoch keep
/// their lowest and highest sample in arrival order (min-max downsampling,
/// 03 §10.7), so a column keeps the same samples while the window moves.
/// Each run reaches one sample past either end of the window, so lines run
/// to the plot's edges.
List<List<int>> timeSeriesRuns(
  TimeSeriesRing ring,
  int lane, {
  required int from,
  required int to,
  required int bucket,
}) {
  assert(bucket > 0, 'a column spans time');
  final runs = <List<int>>[];
  var run = <int>[];
  int? column, lowAt, highAt;

  void endColumn() {
    if (column == null) return;
    final low = lowAt!, high = highAt!;
    run.add(math.min(low, high));
    if (low != high) run.add(math.max(low, high));
    column = null;
  }

  void endRun() {
    endColumn();
    if (run.isNotEmpty) runs.add(run);
    run = <int>[];
  }

  final start = math.max(0, ring.indexAtOrAfter(from) - 1);
  final stop = math.min(ring.length, ring.indexAtOrAfter(to + 1) + 1);
  for (var index = start; index < stop; index++) {
    final value = ring.valueAt(lane, index);
    if (value == null) {
      endRun();
      continue;
    }
    if (run.isNotEmpty || column != null) {
      if (!ring.joinsPrevious(index)) endRun();
    }

    final at = ring.microsAt(index) ~/ bucket;
    if (at != column) {
      endColumn();
      column = at;
      lowAt = highAt = index;
      continue;
    }
    if (value < ring.valueAt(lane, lowAt!)!) lowAt = index;
    if (value > ring.valueAt(lane, highAt!)!) highAt = index;
  }
  endRun();
  return runs;
}

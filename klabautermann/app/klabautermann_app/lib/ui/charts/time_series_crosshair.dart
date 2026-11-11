import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'chart_values.dart';
import 'time_series.dart';

// A time-series chart's crosshair (03 §10.7) as pure functions: what a
// pointer or a key lands on and the words its readout shows. Each works in
// time, not pixels, and costs a binary search and a pass over the gaps in
// view, never a pass over the samples. Kept out of the charts' barrel.

/// What a crosshair points at: a sample, or a time inside a gap. [at] is
/// where its rule stands, in microseconds since the epoch.
@immutable
sealed class TimeSeriesHit {
  const TimeSeriesHit(this.at);

  final int at;
}

/// The sample at [index] in the ring, taken at [at].
final class TimeSeriesSampleHit extends TimeSeriesHit {
  const TimeSeriesSampleHit(this.index, super.at);

  final int index;

  @override
  bool operator ==(Object other) =>
      other is TimeSeriesSampleHit && other.index == index && other.at == at;

  @override
  int get hashCode => Object.hash(index, at);
}

/// A time [at] inside [gap], where no series has a reading.
final class TimeSeriesGapHit extends TimeSeriesHit {
  const TimeSeriesGapHit(this.gap, super.at);

  final ChartGap gap;

  @override
  bool operator ==(Object other) =>
      other is TimeSeriesGapHit && other.gap == gap && other.at == at;

  @override
  int get hashCode => Object.hash(gap, at);
}

/// Where a key moves the crosshair.
enum TimeSeriesStep { earlier, later, oldest, newest }

/// [gap]'s part of the window from [from] to [to].
({int start, int end}) _clip(ChartGap gap, int from, int to) => (
  start: math.max(gap.start.microsecondsSinceEpoch, from),
  end: math.min(gap.end?.microsecondsSinceEpoch ?? to, to),
);

/// What the time [at] lands on in the window from [from] to [to]: a gap
/// of [gaps] whose span holds it, else the nearest sample in the window
/// (the earlier of two equally near), or null when the window holds
/// neither. A gap narrower than twice [gapReach] reaches that far either
/// side of its middle, as its band is drawn wider than its span; a time
/// there outside the span puts the rule at the middle. A sample is never
/// inside a gap: the sample that closes one is taken at its end. A gap
/// still open at the window's right edge holds the edge too.
TimeSeriesHit? timeSeriesHitAt(
  TimeSeriesRing ring,
  List<ChartGap> gaps, {
  required int at,
  required int from,
  required int to,
  int gapReach = 0,
}) {
  final time = at.clamp(from, to);
  for (final gap in gaps) {
    final (:start, :end) = _clip(gap, from, to);
    if (end < start) continue;
    // A gap still open at the window's edge holds the edge itself: no
    // sample closes it there.
    final edge = end == to && (gap.end?.microsecondsSinceEpoch ?? to) >= to
        ? 1
        : 0;
    final middle = start + (end - start) ~/ 2;
    final low = math.min(start, middle - gapReach);
    final high = math.max(end + edge, middle + gapReach);
    if (time <= low || time >= high) continue;
    final inside = time > start && time < end + edge;
    return TimeSeriesGapHit(gap, inside ? time : middle);
  }

  final first = ring.indexAtOrAfter(from);
  final stop = ring.indexAtOrAfter(to + 1);
  if (first >= stop) return null;
  var index = ring.indexAtOrAfter(time).clamp(first, stop - 1);
  final after = ring.microsAt(index);
  if (index > first && after > time) {
    final before = ring.microsAt(index - 1);
    if (time - before <= after - time) index--;
  }
  return TimeSeriesSampleHit(index, ring.microsAt(index));
}

/// Where [step] moves a crosshair at [at] (null for none yet), in the
/// window from [from] to [to]: to a sample, at least [stride]
/// microseconds (a pixel column) away so that a key moves the rule on
/// screen, or to the middle of a gap in view, whichever comes first;
/// within a stride of the window's first or last sample, to that one. A
/// gap without a span of its own (shorter than two microseconds) is no
/// stop. With no crosshair yet, any step goes to the newest stop. At the
/// end of the window it stays at [at]; with nothing in view it gives null.
int? timeSeriesStepFrom(
  TimeSeriesRing ring,
  List<ChartGap> gaps, {
  required int? at,
  required TimeSeriesStep step,
  required int from,
  required int to,
  int stride = 1,
}) {
  final first = ring.indexAtOrAfter(from);
  final stop = ring.indexAtOrAfter(to + 1);
  final middles = [
    for (final gap in gaps)
      if (_clip(gap, from, to) case (
        :final start,
        :final end,
      ) when end - start >= 2)
        start + (end - start) ~/ 2,
  ];
  final oldest = [
    if (first < stop) ring.microsAt(first),
    ...middles.take(1),
  ].fold<int?>(null, (low, time) => low == null ? time : math.min(low, time));
  final newest =
      [
        if (first < stop) ring.microsAt(stop - 1),
        if (middles.isNotEmpty) middles.last,
      ].fold<int?>(
        null,
        (high, time) => high == null ? time : math.max(high, time),
      );
  if (oldest == null) return null;

  final reach = math.max(1, stride);
  switch (step) {
    case TimeSeriesStep.oldest:
      return oldest;
    case TimeSeriesStep.newest:
      return newest;
    case TimeSeriesStep.later:
      if (at == null) return newest;
      // Within a stride of the window's newest sample, that sample.
      final next = math.min(ring.indexAtOrAfter(at + reach), stop - 1);
      final sample = next >= first && ring.microsAt(next) > at
          ? ring.microsAt(next)
          : null;
      final gap = middles.where((middle) => middle > at).firstOrNull;
      return [?sample, ?gap].fold<int?>(
            null,
            (low, time) => low == null ? time : math.min(low, time),
          ) ??
          at;
    case TimeSeriesStep.earlier:
      if (at == null) return newest;
      final previous = math.max(ring.indexAtOrAfter(at - reach + 1) - 1, first);
      final sample = previous < stop && ring.microsAt(previous) < at
          ? ring.microsAt(previous)
          : null;
      final gap = middles.where((middle) => middle < at).lastOrNull;
      return [?sample, ?gap].fold<int?>(
            null,
            (high, time) => high == null ? time : math.max(high, time),
          ) ??
          at;
  }
}

/// A crosshair readout's words: the time, each series' label and value
/// at a sample (none inside a gap), and inside a gap that no series has a
/// reading, with the gap's label.
typedef TimeSeriesReadout = ({String time, List<String> values, String? gap});

/// The readout of [hit] on [ring], whose series are [labels] in [unit].
/// The time reads the wall clock of the zone [zoneOffsetOf] gives, as the
/// chart's ticks do: to the second on a window of up to an hour, to the
/// minute up to a day, and with the date beyond.
TimeSeriesReadout timeSeriesReadout(
  TimeSeriesHit hit,
  TimeSeriesRing ring, {
  required List<String> labels,
  required ChartUnit unit,
  required ChartStrings strings,
  required Duration span,
  required Duration Function(DateTime time) zoneOffsetOf,
}) {
  final utc = DateTime.fromMicrosecondsSinceEpoch(hit.at, isUtc: true);
  // Fields that read the zone's wall clock; only they are formatted.
  final wall = utc.add(zoneOffsetOf(utc));
  final time = span <= const Duration(hours: 1)
      ? strings.timeWithSeconds(wall)
      : span <= const Duration(days: 1)
      ? strings.time(wall)
      : strings.dateTime(wall);
  return switch (hit) {
    TimeSeriesSampleHit(:final index) => (
      time: time,
      values: [
        for (final (lane, label) in labels.indexed)
          strings.barPart(label, switch (ring.valueAt(lane, index)) {
            final value? => formatChartValue(value, unit, strings),
            null => strings.noReading,
          }),
      ],
      gap: null,
    ),
    TimeSeriesGapHit(:final gap) => (
      time: time,
      values: const [],
      gap: strings.noReadingBecause(chartGapLabel(gap.reason, strings)),
    ),
  };
}

/// [readout] as one line, as a screen reader hears it.
String timeSeriesReadoutText(TimeSeriesReadout readout, ChartStrings strings) =>
    [readout.time, ...readout.values, ?readout.gap].join(strings.listSeparator);

/// The label of a band without data for [reason].
String chartGapLabel(ChartGapReason reason, ChartStrings strings) =>
    switch (reason) {
      ChartGapReason.appClosed => strings.gapAppClosed,
      ChartGapReason.background => strings.gapBackground,
      ChartGapReason.disconnected => strings.gapDisconnected,
      ChartGapReason.readingFailed => strings.gapReadingFailed,
    };

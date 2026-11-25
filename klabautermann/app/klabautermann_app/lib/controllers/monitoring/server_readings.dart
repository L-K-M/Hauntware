import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../ui/charts/series_ring.dart';
import '../../ui/charts/time_series.dart';

/// The readings a session ring keeps per series (OV-03): ten minutes at
/// the Desktop `core` cadence of 2 s, 25 at the `overview` cadence of 5 s
/// (03 §6.4).
const int kSessionRingCapacity = 300;

/// The streams whose readings feed [MetricSeries] rings.
const Set<SampleStream> ringStreams = {
  SampleStream.overview,
  SampleStream.core,
};

/// One chart series a session ring keeps (OV-03), read from an `overview`
/// or `core` reading.
enum MetricSeries {
  /// CPU busy in percent ([CpuPercentages.busy]).
  cpuBusy,

  /// Used memory in bytes ([MemoryUsage.usedBytes]).
  memoryUsed,

  /// Used swap in bytes ([MemoryUsage.swapUsedBytes]).
  swapUsed,

  /// The one-minute load average ([LoadAvg.load1]).
  load1;

  /// This series' value in [result], or null when the reading has none:
  /// an unknown value is a gap in the ring, never zero (03 §10.4).
  double? readFrom(SampleResult result) {
    final (cpu, memory, load) = switch (result) {
      OverviewResult(:final cpu, :final memory, :final load) ||
      CoreResult(:final cpu, :final memory, :final load) => (cpu, memory, load),
      _ => (null, null, null),
    };
    return switch (this) {
      cpuBusy => cpu?.busy,
      memoryUsed => memory?.usedBytes?.toDouble(),
      swapUsed => memory?.swapUsedBytes?.toDouble(),
      load1 => load?.load1,
    };
  }
}

/// How old a reading taken [at] is by [now] (03 §9.5 item 4), or null
/// without one. The engine stamps [Sample.at] with this device's clock, so
/// only a clock set back since makes the age negative; that reads as zero.
Duration? sampleAge(DateTime? at, DateTime now) {
  if (at == null) return null;
  final age = now.difference(at);
  return age.isNegative ? Duration.zero : age;
}

/// Why a session history has no data, from a [Gap]'s cause (03 §9.5
/// item 5).
ChartGapReason chartGapReasonOf(GapCause cause) => switch (cause) {
  GapCause.background => ChartGapReason.background,
  GapCause.disconnected => ChartGapReason.disconnected,
  GapCause.readingLost => ChartGapReason.readingFailed,
};

/// What the engine last said sampling a server is doing ([state]), and
/// the phase before it ([previous]; null for the first this engine run).
/// The protocol has the engine send a [SamplingState] at each phase
/// change, so the pair tells a link lost while sampling, whose loss
/// `state.since` dates, from one already down when a view or the return
/// from the background subscribed the server again, whose phase began
/// only then (03 §9.5 item 4).
@immutable
final class SamplingStatus {
  const SamplingStatus(this.state, {this.previous});

  final SamplingState state;
  final SamplingPhase? previous;
}

/// What opened a history gap: a [SamplingState] phase, or a [Gap] or
/// failed reading, which never relabels an open one.
enum _HistoryGapSource { phase, reading }

/// One server's readings: its seq floor, latest sample and latest reading
/// per stream, rings and probe profile.
final class ServerReadings {
  /// The highest [Sample.seq] kept: the engine counts one sequence per
  /// server across its streams (D44).
  int? _lastSeq;

  final Map<SampleStream, ValueNotifier<Sample?>> _boxes = {};
  final Map<SampleStream, ValueNotifier<Sample?>> _lastReadings = {};
  final Map<SampleStream, Map<MetricSeries, SeriesRing>> _rings = {};
  final ValueNotifier<HostProfile?> profile = ValueNotifier(null);
  final ValueNotifier<ServerClock?> clock = ValueNotifier(null);

  /// Ring streams no subscription names, and those named again since,
  /// whose next reading follows a hole.
  final Set<SampleStream> _unnamed = {};
  final Set<SampleStream> _afterHole = {};

  /// The engine's latest [SamplingState] for the server, with the phase
  /// before it.
  final ValueNotifier<SamplingStatus?> sampling = ValueNotifier(null);

  /// The `core` stream's series on a time axis, made on first use: rows
  /// read every fleet server's boxes, and only open servers sample `core`.
  Map<MetricSeries, TimeSeriesRing>? _history;
  Map<MetricSeries, TimeSeriesRing> get history => _history ??= {
    for (final series in MetricSeries.values)
      series: TimeSeriesRing(capacity: kSessionRingCapacity, lanes: 1),
  };
  Iterable<TimeSeriesRing> get _historyRings => _history?.values ?? const [];

  /// Opens a gap at [at] in every history ring that has a reading, as
  /// the engine gives a stream without one no gap. From the phase, a
  /// background pause or a lost link outranks a lost reading (03 §10.1),
  /// and a change between them starts a band of its own; a [Gap] or a
  /// failed reading opens one only where none is open, since the open
  /// one already says why readings stopped.
  void _openHistoryGap(
    DateTime at,
    ChartGapReason reason,
    _HistoryGapSource source,
  ) {
    if (_unnamed.contains(SampleStream.core)) return;
    for (final ring in _historyRings) {
      final last = ring.gaps.lastOrNull;
      final open = last != null && last.end == null;
      if (ring.length == 0) continue;
      if (open && source == _HistoryGapSource.reading) continue;
      ring.openGap(at, reason);
    }
  }

  /// The background pause, and a link lost while sampling, stop readings
  /// as the phase changes; a return with the link down ends the
  /// background's gap, as the app is in the foreground from then on.
  void phaseChanged(SamplingStatus status) {
    final reason = switch (status.state.phase) {
      SamplingPhase.pausedInBackground => ChartGapReason.background,
      SamplingPhase.waitingForLink
          when status.previous == SamplingPhase.sampling ||
              status.previous == SamplingPhase.pausedInBackground =>
        ChartGapReason.disconnected,
      _ => null,
    };
    if (reason == null) return;
    _openHistoryGap(status.state.since, reason, _HistoryGapSource.phase);
  }

  /// [gap] precedes the readings that resume its streams: none joins the
  /// reading before it.
  void gap(Gap gap) {
    for (final stream in gap.streams.where(ringStreams.contains)) {
      _afterHole.add(stream);
    }
    if (gap.streams.contains(SampleStream.core)) {
      _openHistoryGap(
        gap.from,
        chartGapReasonOf(gap.cause),
        _HistoryGapSource.reading,
      );
    }
  }

  void unnamed(SampleStream stream, DateTime now) {
    _unnamed.add(stream);
    if (stream != SampleStream.core) return;
    for (final ring in _historyRings) {
      if (ring.length > 0) ring.add(now, const [null]);
    }
  }

  void named(SampleStream stream) {
    if (_unnamed.remove(stream)) _afterHole.add(stream);
  }

  ValueNotifier<Sample?> box(SampleStream stream) =>
      _boxes.putIfAbsent(stream, () => ValueNotifier<Sample?>(null));

  ValueNotifier<Sample?> lastReading(SampleStream stream) =>
      _lastReadings.putIfAbsent(stream, () => ValueNotifier<Sample?>(null));

  /// Every series of [stream] at once, so they stay aligned sample for
  /// sample.
  Map<MetricSeries, SeriesRing> rings(SampleStream stream) =>
      _rings.putIfAbsent(
        stream,
        () => {
          for (final series in MetricSeries.values)
            series: SeriesRing(kSessionRingCapacity),
        },
      );

  /// Keeps [sample] unless its seq is not above the floor.
  void accept(Sample sample) {
    final last = _lastSeq;
    if (last != null && sample.seq <= last) return;
    _lastSeq = sample.seq;

    // Rings first: a surface that hears the box may read them too.
    if (ringStreams.contains(sample.stream)) {
      // Marked as the next reading arrives rather than when the stream is
      // named again: a reading still in flight then belongs before it.
      final hole = _afterHole.remove(sample.stream);
      for (final MapEntry(key: series, value: ring) in rings(
        sample.stream,
      ).entries) {
        if (hole && ring.length > 0) ring.add(null);
        ring.add(series.readFrom(sample.result));
      }
    }
    if (sample.stream == SampleStream.core) _record(sample);
    if (sample.result is! CollectorUnavailable) {
      lastReading(sample.stream).value = sample;
    }
    box(sample.stream).value = sample;
  }

  /// Adds [sample] to the history rings; a failed reading opens a gap.
  void _record(Sample sample) {
    if (sample.result is CollectorUnavailable) {
      _openHistoryGap(
        sample.at,
        ChartGapReason.readingFailed,
        _HistoryGapSource.reading,
      );
      return;
    }
    for (final MapEntry(key: series, value: ring) in history.entries) {
      ring.add(sample.at, [series.readFrom(sample.result)]);
    }
  }

  /// Drops every reading, ring, profile and clock, keeping each box for
  /// the views that hold it. The seq floor stays: the engine's count for
  /// the server goes on (D44).
  void clear() {
    for (final box in [..._boxes.values, ..._lastReadings.values]) {
      box.value = null;
    }
    for (final ring in _rings.values.expand((rings) => rings.values)) {
      ring.clear();
    }
    for (final ring in _historyRings) {
      ring.clear();
    }
    _afterHole.clear();
    profile.value = null;
    clock.value = null;
  }

  void dispose() {
    sampling.dispose();
    for (final ring in _historyRings) {
      ring.dispose();
    }
    for (final box in [..._boxes.values, ..._lastReadings.values]) {
      box.dispose();
    }
    for (final ring in _rings.values.expand((rings) => rings.values)) {
      ring.dispose();
    }
    profile.dispose();
    clock.dispose();
  }
}

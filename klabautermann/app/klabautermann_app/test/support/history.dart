import 'package:klabautermann_core/klabautermann_core.dart';

/// The History tests' clock: a fixed noon, in UTC as the engine keeps it.
final historyT0 = DateTime.utc(2026, 10, 25, 12);

/// [minutes] after [historyT0].
DateTime historyAt(int minutes) => historyT0.add(Duration(minutes: minutes));

/// A 1-minute bucket at [minute] whose CPU busy reads [mean], peaking at
/// [mean] plus ten.
HistoryBucket historyBucket(int minute, double mean) => HistoryBucket(
  start: historyAt(minute),
  provenance: HistoryProvenance.liveSampler,
  values: {
    AlertMetric.cpuBusy: HistoryStat(
      min: mean - 5,
      max: mean + 10,
      mean: mean,
      count: 12,
    ),
  },
);

/// 33 of the 48 hours [historyNow] shows, in 1-minute buckets, with
/// each kind of gap the chart labels: the link down for four hours, the
/// app in the background for four, the app closed for four with no cause
/// recorded, readings lost for one, and the last two not yet recorded.
HistoryRange historySample() {
  final buckets = <HistoryBucket>[];
  void run(int fromHour, int untilHour) {
    for (var minute = fromHour * 60; minute < untilHour * 60; minute++) {
      final wave = (minute % 300) / 300;
      buckets.add(historyBucket(minute, 30 + 40 * wave));
    }
  }

  run(0, 10);
  run(14, 22);
  run(26, 34);
  run(38, 44);
  run(45, 46);
  return HistoryRange(
    buckets: buckets,
    gaps: [
      HistoryGap(
        from: historyAt(10 * 60),
        until: historyAt(14 * 60),
        cause: GapCause.disconnected,
      ),
      HistoryGap(
        from: historyAt(22 * 60),
        until: historyAt(26 * 60),
        cause: GapCause.background,
      ),
      HistoryGap(
        from: historyAt(44 * 60),
        until: historyAt(45 * 60),
        cause: GapCause.readingLost,
      ),
    ],
  );
}

/// The moment [historySample] is read: 48 hours after [historyT0].
final historyNow = historyAt(48 * 60);

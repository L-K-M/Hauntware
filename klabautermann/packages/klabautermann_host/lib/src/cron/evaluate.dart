/// Next-run evaluation for cron expressions in a server time zone
/// (03 §7.7). The zone is the probe's fixed offset plus an optional
/// IANA rule carrier, because Dart ships no zoneinfo; DST transitions
/// are detected as offset jumps and annotated so the UI can mark runs
/// that fire inside a spring-forward gap or the first pass of a
/// fall-back overlap.
library;

import 'package:meta/meta.dart';

import 'expression.dart';

/// A server time zone (03 §7.7): the fixed offset always present, and
/// an optional rule lookup the embedding platform may supply from the
/// probe's `timezone` name.
@immutable
final class ServerZone {
  const ServerZone({required this.offset, this.ianaName, this.offsetAt});

  /// The fixed offset from the probe's `zoneOffset` (`+0200`). Used when
  /// [offsetAt] is absent and as a sanity anchor.
  final Duration offset;

  /// The IANA name from the probe's `timezone` (`Europe/Berlin`).
  final String? ianaName;

  /// Returns the zone's offset at an instant, or null when unknown.
  /// Supplied by the consumer (e.g. a `timezone` package lookup in
  /// klabautermann_core); absent means fixed-offset evaluation.
  final Duration Function(DateTime utcInstant)? offsetAt;

  /// The offset at [utcInstant]; falls back to the fixed offset.
  Duration offsetFor(DateTime utcInstant) =>
      offsetAt?.call(utcInstant) ?? offset;
}

/// DST annotation for one predicted run (03 §7.7).
enum CronDst {
  /// An ordinary wall-clock minute.
  none,

  /// The wall minute is skipped by a forward transition; the run fires
  /// at the transition instant, which is cronie's gap behavior.
  gap,

  /// The wall minute occurs twice around a backward transition; the run
  /// fires at the first occurrence.
  overlap,
}

/// One predicted run (03 §7.7).
@immutable
final class CronRun {
  const CronRun({
    required this.atUtc,
    required this.wall,
    required this.offset,
    required this.dst,
  });

  /// The instant the run fires.
  final DateTime atUtc;

  /// The matched wall-clock minute (fields carry the zone's clock).
  final DateTime wall;

  /// The zone offset in effect at [atUtc].
  final Duration offset;

  /// How this run relates to a DST transition.
  final CronDst dst;

  Map<String, Object?> toJson() => {
    'atUtc': atUtc.toIso8601String(),
    'wall': wall.toIso8601String(),
    'offsetMinutes': offset.inMinutes,
    'dst': dst.name,
  };
}

/// Lists up to [count] runs of [expression] strictly after [afterUtc]
/// (03 §7.7). Never throws: a reboot expression or a nonpositive count
/// yields an empty list, and the scan gives up after [horizonDays].
///
/// Stepping happens in instants: days that cannot match jump to the next
/// wall midnight, matching days walk minute by minute, and a wall-clock
/// jump between consecutive instants marks a DST transition. Gap jobs
/// (cronie fires them at the transition instant, within a 3-hour
/// window) and first-occurrence overlap jobs are annotated [CronDst].
List<CronRun> nextCronRuns(
  CronExpression expression, {
  required DateTime afterUtc,
  required ServerZone zone,
  int count = 5,
  int horizonDays = 3653,
}) {
  final runs = <CronRun>[];
  if (expression.isReboot || count <= 0 || horizonDays <= 0) return runs;

  final limit = afterUtc.add(Duration(days: horizonDays));
  final emitted = <int>{};
  var t = _afterMinute(afterUtc);
  int? prevWallMs;
  while (runs.length < count && t.isBefore(limit)) {
    final offset = zone.offsetFor(t);
    final wallMs = t.millisecondsSinceEpoch + offset.inMilliseconds;
    final wall = DateTime.fromMillisecondsSinceEpoch(wallMs, isUtc: true);
    if (!_dayCanMatch(expression, wall)) {
      // Jump to just under the next wall midnight; the evaluator then
      // walks forward minute by minute across whatever the clock does.
      final midnight = DateTime.utc(wall.year, wall.month, wall.day + 1);
      var jumpMs =
          midnight.millisecondsSinceEpoch -
          wallMs -
          const Duration(hours: 3).inMilliseconds;
      if (jumpMs < 60000) jumpMs = 60000;
      t = t.add(Duration(milliseconds: jumpMs));
      prevWallMs = null;
      continue;
    }
    if (prevWallMs != null) {
      final advance = wallMs - prevWallMs;
      if (advance > 60000 && advance <= _maxGapMs) {
        // Forward jump: skipped wall minutes that match fire at the
        // transition instant (cronie notices within 3 hours).
        for (var w = prevWallMs + 60000; w < wallMs; w += 60000) {
          final skipped = DateTime.fromMillisecondsSinceEpoch(w, isUtc: true);
          if (expression.matches(skipped)) {
            _emit(runs, emitted, w, t, offset, CronDst.gap, count);
          }
        }
      }
    }
    if (expression.matches(wall)) {
      final dst = _repeatsWithin(zone, t, wallMs, offset)
          ? CronDst.overlap
          : CronDst.none;
      _emit(runs, emitted, wallMs, t, offset, dst, count);
    }
    prevWallMs = wallMs;
    t = t.add(const Duration(minutes: 1));
  }
  return runs;
}

/// The first instant-minute strictly after [afterUtc].
DateTime _afterMinute(DateTime afterUtc) {
  final truncated = DateTime.fromMillisecondsSinceEpoch(
    afterUtc.millisecondsSinceEpoch - afterUtc.millisecondsSinceEpoch % 60000,
    isUtc: true,
  );
  return truncated.add(const Duration(minutes: 1));
}

/// Whether [wall]'s day fields can match at all; hour/minute are
/// deliberately ignored so midnight-first jobs are not skipped.
bool _dayCanMatch(CronExpression e, DateTime wall) {
  if (!e.months.contains(wall.month)) return false;
  final dom = e.monthDays.contains(wall.day);
  final dow = e.weekDays.contains(wall.weekday % 7);
  if (e.domStar || e.dowStar) return dom && dow;
  return dom || dow;
}

/// The wall-clock jump bound for treating skipped minutes as gap jobs:
/// cronie runs them when noticed within 3 hours.
const _maxGapMs = 3 * 3600 * 1000;

void _emit(
  List<CronRun> runs,
  Set<int> emitted,
  int wallMs,
  DateTime atUtc,
  Duration offset,
  CronDst dst,
  int count,
) {
  if (runs.length >= count || !emitted.add(wallMs)) return;
  runs.add(
    CronRun(
      atUtc: atUtc,
      wall: DateTime.fromMillisecondsSinceEpoch(wallMs, isUtc: true),
      offset: offset,
      dst: dst,
    ),
  );
}

/// True when [wallMs] occurs a second time within 4 hours after instant
/// [t] — a backward offset transition repeats the wall interval
/// `[t_s + offNew, t_s + offOld)`.
bool _repeatsWithin(ServerZone zone, DateTime t, int wallMs, Duration offNow) {
  final probeEnd = t.add(const Duration(hours: 4));
  final offEnd = zone.offsetFor(probeEnd);
  if (offEnd >= offNow) return false;
  // The offset decreases inside the window: find the transition instant
  // (the first minute carrying a different offset).
  for (
    var tt = t.add(const Duration(minutes: 1));
    !tt.isAfter(probeEnd);
    tt = tt.add(const Duration(minutes: 1))
  ) {
    final o = zone.offsetFor(tt);
    if (o == offNow) continue;
    final repStart = tt.millisecondsSinceEpoch + o.inMilliseconds;
    final repEnd = tt.millisecondsSinceEpoch + offNow.inMilliseconds;
    return wallMs >= repStart && wallMs < repEnd;
  }
  return false;
}

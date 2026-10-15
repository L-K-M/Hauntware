/// Next-run evaluation for cron expressions in a server time zone
/// (03 §7.7). The zone is the probe's fixed offset plus an optional
/// IANA rule carrier, because Dart ships no zoneinfo; DST transitions
/// are detected as offset jumps and annotated so the UI can mark runs
/// that fire inside a spring-forward gap, in the first pass of a
/// fall-back overlap, or otherwise within an hour of a transition (D57).
/// A line follows the server's clock or, under `CRON_TZ`, its own
/// zone's ([CronClock]).
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

  /// Returns the zone's offset at an instant. klabautermann_core
  /// supplies it from `package:timezone`'s rules for [ianaName] (D57);
  /// absent means fixed-offset evaluation.
  final Duration Function(DateTime utcInstant)? offsetAt;

  /// The offset at [utcInstant]; falls back to the fixed offset.
  Duration offsetFor(DateTime utcInstant) =>
      offsetAt?.call(utcInstant) ?? offset;
}

/// Which clock a cron line's schedule follows across DST transitions
/// (03 §7.7, D57), after cronie's `find_jobs` [R: cron.c].
enum CronClock {
  /// The cron daemon's own clock in the server's zone, for a line
  /// without `CRON_TZ`. A fixed-time job runs the minutes a forward jump
  /// skips at the jump, and a backward jump's repeated minutes once.
  server,

  /// The line's `CRON_TZ` zone. cron converts each minute of its own
  /// clock into that zone and matches there, so a fixed-time job misses
  /// the minutes the zone's forward jump skips and matches the minutes
  /// its backward jump repeats twice. While the server's zone repeats an
  /// hour, cron runs no fixed-time job at all, which leaves one run when
  /// both zones fall back by the same amount at the same instant.
  line,
}

/// DST annotation for one predicted run (03 §7.7).
enum CronDst {
  /// An ordinary wall-clock minute.
  none,

  /// The wall minute is skipped by a forward transition; a fixed-time
  /// job fires at the transition instant, which is cronie's gap behavior.
  /// A [CronClock.line] job misses the minute instead, so its runs never
  /// carry this mark.
  gap,

  /// The wall minute occurs twice around a backward transition; a
  /// fixed-time job fires at the first occurrence only. A
  /// [CronClock.line] job fires at each occurrence outside the server
  /// zone's repeated hour, and carries this mark only on a first
  /// occurrence whose second falls in that hour; its other runs within
  /// an hour of a transition are [nearTransition].
  overlap,

  /// An ordinary wall minute within an hour of a transition, of the
  /// line's zone or, for a [CronClock.line] job, the server's. The
  /// client's zone database may place the transition elsewhere than the
  /// server's, which cron reads, so the run may fire an hour off, or
  /// not at all near the server zone's fall-back (D57).
  nearTransition,
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
/// (03 §7.7) by [clock] in [zone]: the server's zone for
/// [CronClock.server], the line's for [CronClock.line]. A line clock
/// takes the server's zone as [serverZone], whose repeated hours hold
/// back fixed-time runs and whose transitions mark the runs near them;
/// null when it is unknown, which does neither. Never throws: a reboot
/// expression or a nonpositive count yields an empty list, and the scan
/// gives up after [horizonDays].
///
/// Stepping happens in instants: days that cannot match jump to the next
/// wall day that can, matching days walk minute by minute, and a wall-clock
/// jump between consecutive instants marks a DST transition. Gap jobs
/// on the server clock (cronie fires them at the transition instant,
/// within a 3-hour window), first-occurrence overlap jobs and other runs
/// within an hour of a transition are annotated [CronDst].
///
/// On the server clock, cronie and Debian's cron catch up skipped
/// minutes and skip repeated ones only for fixed-time jobs;
/// [CronClock.line] gives cronie's `CRON_TZ` rule. A wildcard job
/// ([CronExpression.hasWildcardTime]) runs by the clock on either:
/// never in a gap, and in both passes of an overlap.
List<CronRun> nextCronRuns(
  CronExpression expression, {
  required DateTime afterUtc,
  required ServerZone zone,
  CronClock clock = CronClock.server,
  ServerZone? serverZone,
  int count = 5,
  int horizonDays = 3653,
}) {
  assert(
    clock == CronClock.line || serverZone == null,
    'the server clock runs in zone; only a line clock takes serverZone',
  );
  final runs = <CronRun>[];
  if (expression.isReboot || count <= 0 || horizonDays <= 0) return runs;

  final limit = afterUtc.add(Duration(days: horizonDays));
  final wildcard = expression.hasWildcardTime;
  // cron catches up only its own clock's gaps, and its repeated hour
  // holds back every fixed-time job, whatever zone the line names.
  final catchUp = !wildcard && clock == CronClock.server;
  final server = clock == CronClock.server ? zone : serverZone;
  var t = _afterMinute(afterUtc);
  // The wall clock one minute before [t]: a forward jump into [t] runs
  // its skipped minutes at [t] even when [t] is the first instant.
  var prevWallMs = _wallMsAt(zone, t.subtract(_minute));
  while (runs.length < count && t.isBefore(limit)) {
    final offset = zone.offsetFor(t);
    final wallMs = t.millisecondsSinceEpoch + offset.inMilliseconds;
    final wall = DateTime.fromMillisecondsSinceEpoch(wallMs, isUtc: true);
    if (catchUp) {
      final advance = wallMs - prevWallMs;
      if (advance > 60000 && advance <= _maxGapMs) {
        // Forward jump: skipped wall minutes that match fire at the
        // transition instant (cronie notices within 3 hours). Each
        // minute matches with its own date, before the day check, since
        // [wall]'s day may differ from theirs.
        for (var w = prevWallMs + 60000; w < wallMs; w += 60000) {
          final skipped = DateTime.fromMillisecondsSinceEpoch(w, isUtc: true);
          if (expression.matches(skipped)) {
            _emit(runs, w, t, offset, CronDst.gap, count);
          }
        }
      }
    }
    if (!_dayCanMatch(expression, wall)) {
      // Find the next wall day that can match by date arithmetic alone,
      // then jump to just under its midnight; the evaluator walks forward
      // minute by minute from there across whatever the clock does. The
      // 3-hour margin absorbs an offset rise until then.
      final stopMs = limit.millisecondsSinceEpoch + offset.inMilliseconds;
      var midnight = DateTime.utc(wall.year, wall.month, wall.day + 1);
      while (!_dayCanMatch(expression, midnight) &&
          midnight.millisecondsSinceEpoch <= stopMs) {
        midnight = DateTime.utc(
          midnight.year,
          midnight.month,
          midnight.day + 1,
        );
      }
      var jumpMs =
          midnight.millisecondsSinceEpoch -
          wallMs -
          const Duration(hours: 3).inMilliseconds;
      if (jumpMs < 60000) jumpMs = 60000;
      t = t.add(Duration(milliseconds: jumpMs));
      prevWallMs = jumpMs == 60000
          ? wallMs
          : _wallMsAt(zone, t.subtract(_minute));
      continue;
    }
    // cron runs no fixed-time job in its repeated pass: on its own
    // clock, that minute has already run.
    if (expression.matches(wall) &&
        (wildcard || server == null || !_repeatedPass(server, t))) {
      final second = wildcard ? null : _secondPass(zone, t, wallMs, offset);
      final dst =
          second != null && server != null && _repeatedPass(server, second)
          ? CronDst.overlap
          : _nearTransition(zone, t) ||
                (server != null && _nearTransition(server, t))
          ? CronDst.nearTransition
          : CronDst.none;
      _emit(runs, wallMs, t, offset, dst, count);
    }
    prevWallMs = wallMs;
    t = t.add(const Duration(minutes: 1));
  }
  return runs;
}

const _minute = Duration(minutes: 1);

/// The zone's wall clock at instant [t], in milliseconds.
int _wallMsAt(ServerZone zone, DateTime t) =>
    t.millisecondsSinceEpoch + zone.offsetFor(t).inMilliseconds;

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

/// Adds a run unless [count] are listed. Instants only move forward and
/// skipped wall minutes never recur, so no run repeats.
void _emit(
  List<CronRun> runs,
  int wallMs,
  DateTime atUtc,
  Duration offset,
  CronDst dst,
  int count,
) {
  if (runs.length >= count) return;
  runs.add(
    CronRun(
      atUtc: atUtc,
      wall: DateTime.fromMillisecondsSinceEpoch(wallMs, isUtc: true),
      offset: offset,
      dst: dst,
    ),
  );
}

/// Whether the offset changes in `(t - 1h, t + 1h]`: a run at [t] fires
/// within an hour of a transition. Two transitions inside that window
/// would cancel out and leave the run unmarked.
bool _nearTransition(ServerZone zone, DateTime t) =>
    zone.offsetFor(t.subtract(_hour)) != zone.offsetFor(t.add(_hour));

const _hour = Duration(hours: 1);

/// True when [zone]'s wall clock at instant [t] already occurred within
/// 4 hours before: [t] lies in the repeated pass of a backward
/// transition, whose first pass ran at the earlier offset.
bool _repeatedPass(ServerZone zone, DateTime t) {
  final offNow = zone.offsetFor(t);
  final offBefore = zone.offsetFor(t.subtract(const Duration(hours: 4)));
  if (offBefore <= offNow) return false;
  final first = DateTime.fromMillisecondsSinceEpoch(
    t.millisecondsSinceEpoch + offNow.inMilliseconds - offBefore.inMilliseconds,
    isUtc: true,
  );
  return first.isBefore(t) && zone.offsetFor(first) == offBefore;
}

/// The instant [wallMs] occurs a second time within 4 hours after
/// instant [t], or null: a backward offset transition at `t_s` repeats
/// the wall interval `[t_s + offNew, t_s + offOld)`.
DateTime? _secondPass(
  ServerZone zone,
  DateTime t,
  int wallMs,
  Duration offNow,
) {
  final probeEnd = t.add(const Duration(hours: 4));
  final offEnd = zone.offsetFor(probeEnd);
  if (offEnd >= offNow) return null;
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
    if (wallMs < repStart || wallMs >= repEnd) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      wallMs - o.inMilliseconds,
      isUtc: true,
    );
  }
  return null;
}

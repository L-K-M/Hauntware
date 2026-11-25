import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';
import 'jobs_view.dart';
import 'sortable_table.dart';

/// The DST icon after a next run and the gap before it.
const double _dstIconSize = 14;
const double _dstIconGap = 4;

/// A table cell's horizontal padding, both sides: [SortableTable]'s.
const double _cellPadding = 16;

/// The jobs table's columns, whose names key them.
enum JobsColumn { job, source, schedule, next }

/// The first of [job]'s cron runs after [now], so a run the clock has
/// passed since the reading never reads as next; null for a timer, and
/// once every listed run has passed.
CronRun? _cronRunAfter(JobEntry job, DateTime now) =>
    cronRuns(job).$1.where((run) => run.atUtc.isAfter(now)).firstOrNull;

/// When [job] runs next after [now]. systemd lists one elapse per timer,
/// so once the clock passes it the next one waits for the next reading.
DateTime? nextRunAfter(JobEntry job, DateTime now) => switch (job) {
  TimerJobEntry(timer: SystemdTimer(:final nextUtc?))
      when nextUtc.isAfter(now) =>
    nextUtc,
  TimerJobEntry() => null,
  _ => _cronRunAfter(job, now)?.atUtc,
};

/// The jobs table's columns: the job, its source and schedule where the
/// panel is [wide], and its next run after [now].
List<SortableTableColumn<JobEntry>> jobColumns(
  BuildContext context,
  List<JobEntry> jobs, {
  required bool wide,
  required bool stale,
  required Duration? serverOffset,
  required DateTime now,
  List<AnacronJob> anacron = const [],
}) {
  final l10n = AppLocalizations.of(context);
  ({String time, bool dst}) next(JobEntry job) =>
      _next(l10n, job, serverOffset, now, anacron);
  return [
    SortableTableColumn(
      id: JobsColumn.job.name,
      label: l10n.jobsColumnJob,
      // What a screen reader hears of the cell: the name and its badges.
      text: (entry) => switch (entry) {
        CronJobEntry(:final job) => [
          if (job.paused) l10n.jobsPaused,
          if (job.managedBy case final manager?)
            l10n.jobsManagedBy(manager.name),
        ].fold(jobTitle(entry), l10n.jobsBadged),
        _ => jobTitle(entry),
      },
      sortKey: jobTitle,
      extent: const FlexColumnExtent(3),
      cell: (context, job) => _JobCell(job),
    ),
    if (wide)
      SortableTableColumn(
        id: JobsColumn.source.name,
        label: l10n.jobsColumnSource,
        text: (job) => sourceText(l10n, job),
        sortKey: (job) => sourceText(l10n, job),
        extent: const FlexColumnExtent(2),
      ),
    if (wide)
      SortableTableColumn(
        id: JobsColumn.schedule.name,
        label: l10n.jobsColumnSchedule,
        text: (job) => _scheduleCell(l10n, job, anacron),
        extent: const FlexColumnExtent(3),
      ),
    SortableTableColumn(
      id: JobsColumn.next.name,
      label: l10n.jobsColumnNext,
      text: (job) => switch (next(job)) {
        (:final time, dst: true) => l10n.jobsNextRunDst(time),
        (:final time, dst: false) => time,
      },
      sortKey: (job) => nextRunAfter(job, now),
      extent: FixedColumnExtent(
        _nextWidth(context, jobs.map(next), base: wide ? 224 : 176),
      ),
      cell: (context, job) => _NextCell(next(job), stale: stale),
    ),
  ];
}

/// The next-run column's width at a text scale of 1: [base], or as wide
/// as the longest of [nexts] where a row holds one line, as a dense
/// desktop row does at any width, so no time loses the offset or zone
/// after it that tells it from the server's clock (CN-02). A touch row
/// wraps it instead ([_NextCell]), and a panel too narrow for the widened
/// table scrolls it sideways, as it does for large text.
double _nextWidth(
  BuildContext context,
  Iterable<({String time, bool dst})> nexts, {
  required double base,
}) {
  // The table's Material gives its cells the theme's body text.
  final style = Theme.of(context).textTheme.bodyMedium;
  if (_nextLines(context, scaledGhostFileRowExtent(context), style) > 1) {
    return base;
  }

  final scaler = MediaQuery.textScalerOf(context);
  final painter = TextPainter(
    textDirection: Directionality.of(context),
    textScaler: scaler,
    maxLines: 1,
  );
  // The table scales a fixed width with the text, so the text's goes
  // back to a scale of 1; the icon and the cell's padding do not scale.
  final unscale = 1 / scaler.scale(1);
  var width = 0.0;
  for (final next in nexts) {
    painter
      ..text = TextSpan(text: next.time, style: style)
      ..layout();
    final icon = next.dst ? _dstIconGap + _dstIconSize : 0;
    width = math.max(width, painter.width * unscale + icon);
  }
  painter.dispose();

  // A step of 8 keeps the column steady while the times' digits change.
  final fit = ((width + _cellPadding) / 8).ceil() * 8.0;
  return math.max(base, fit);
}

/// A row's first schedule in words, why a cron row has none (naming the
/// anacron job that drives it where its table has one, JOB-04), or that
/// a timer's triggers are not read.
String _scheduleCell(
  AppLocalizations l10n,
  JobEntry job,
  List<AnacronJob> anacron,
) {
  if (job case TimerJobEntry(triggers: null)) {
    return l10n.jobsTimerTriggersUnread;
  }
  if (job.schedules.firstOrNull case final schedule?) {
    return scheduleText(l10n, schedule);
  }
  return runsUnknownFor(l10n, job, anacron);
}

/// A row's next run after [now] on its zone's clock, and whether a DST
/// change marks it: a timer's at the server's offset now, which it names
/// (systemd gives an instant, and no zone rules for it reach the app, so
/// after a DST change it differs from the server's clock); a cron run
/// with the `CRON_TZ` zone it follows, or with its offset when the row's
/// lines follow different zones, as a periodic script's may.
({String time, bool dst}) _next(
  AppLocalizations l10n,
  JobEntry job,
  Duration? serverOffset,
  DateTime now,
  List<AnacronJob> anacron,
) {
  if (job is TimerJobEntry) {
    final offset = serverOffset ?? Duration.zero;
    final time = switch (nextRunAfter(job, now)) {
      final next? => l10n.jobsNextRunAtOffset(
        wallAt(next, offset),
        utcOffsetText(l10n, offset),
      ),
      // The sampler runs list-timers under TZ=UTC, so every time it
      // prints converts. What gives no instant, systemd's n/a or a
      // malformed cell, reads as unknown on both paths, as does an
      // elapse the clock has passed since the reading.
      null => l10n.chartUnknownValue,
    };
    return (time: time, dst: false);
  }

  // A directory anacron drives names its timing when its table has the
  // matching job (JOB-04).
  final anacronTiming = anacronNextFor(l10n, job, anacron);
  if (anacronTiming != null) return (time: anacronTiming, dst: false);

  final run = _cronRunAfter(job, now);
  if (run == null) {
    // The engine's reason in short, which the phone keeps when it drops
    // the schedule column; unknown once every listed run has passed.
    final (_, unknown) = cronRuns(job);
    final time = unknown == null
        ? l10n.chartUnknownValue
        : l10n.jobsNextRunUnknown(unknown.name, kCronHorizonDays ~/ 365);
    return (time: time, dst: false);
  }

  final zones = {
    for (final s in job.schedules)
      if (s is CronSchedule) s.timeZone,
  };
  final wall = wallAt(run.atUtc, run.offset);
  final time = switch (zones) {
    // The merged runs do not say which line each came from, so no one
    // zone name fits them.
    Set(length: != 1) => l10n.jobsNextRunAtOffset(
      wall,
      utcOffsetText(l10n, run.offset),
    ),
    Set(single: final zone?) => l10n.jobsRunInZone(
      l10n.jobsNextRun(wall),
      zone,
    ),
    _ => l10n.jobsNextRun(wall),
  };
  return (time: time, dst: run.dst != CronDst.none);
}

/// A row's name, with an icon for a paused cron line (JOB-07) and one
/// for a line another manager owns (JOB-09); the column's text names
/// them for screen readers, so neither is told by colour (A11Y-01).
class _JobCell extends StatelessWidget {
  const _JobCell(this.job);

  final JobEntry job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final cron = switch (job) {
      CronJobEntry(:final job) => job,
      _ => null,
    };
    return Row(
      spacing: 4,
      children: [
        Flexible(
          child: Text(
            jobTitle(job),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (cron?.paused ?? false)
          Icon(
            Icons.pause_circle_outline,
            size: _dstIconSize,
            color: muted,
            semanticLabel: l10n.jobsPaused,
          ),
        if (cron?.managedBy case final manager?)
          Icon(
            Icons.lock_outline,
            size: _dstIconSize,
            color: muted,
            semanticLabel: l10n.jobsManagedBy(manager.name),
          ),
      ],
    );
  }
}

/// A next run, grey while stale beside the freshness line's history icon
/// (03 §9.5 item 4), with an icon when a DST change marks it; the column's
/// text names the change, and the details say what it does.
///
/// It wraps onto a second line where the row holds one, as a touch row
/// does at any text scale, so the offset or zone after the time, which
/// tells it from the server's clock (CN-02), is not cut at phone width;
/// a dense desktop row holds one line, and its column widens to fit it
/// ([_nextWidth]).
class _NextCell extends StatelessWidget {
  const _NextCell(this.next, {required this.stale});

  final ({String time, bool dst}) next;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = stale ? TextStyle(color: muted) : null;
    return LayoutBuilder(
      builder: (context, box) {
        final lines = _nextLines(
          context,
          box.maxHeight,
          DefaultTextStyle.of(context).style.merge(style),
        );
        return Row(
          spacing: _dstIconGap,
          children: [
            Flexible(
              child: Text(
                next.time,
                maxLines: lines,
                overflow: TextOverflow.ellipsis,
                softWrap: lines > 1,
                style: style,
              ),
            ),
            if (next.dst)
              Icon(Icons.info_outline, size: _dstIconSize, color: muted),
          ],
        );
      },
    );
  }
}

/// How many lines of a next run in [style] at the ambient text scale a
/// row [extent] high holds: two on a touch row, one on a dense one.
int _nextLines(BuildContext context, double extent, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  );
  final height = painter.preferredLineHeight;
  painter.dispose();
  return extent >= 2 * height ? 2 : 1;
}

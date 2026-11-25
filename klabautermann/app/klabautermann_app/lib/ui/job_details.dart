import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';
import 'jobs_table.dart' show nextRunAfter;
import 'jobs_view.dart';

/// One job in full (JOB-02): its source, a cron line's fields as written
/// or the unit a timer starts, every schedule in words, and its runs after
/// [now], each on its zone's clock with that zone's offset and any DST
/// note; for a timer, its random delay and, below systemd 242, that only
/// the next calendar run is listed.
class JobDetails extends StatelessWidget {
  const JobDetails({
    super.key,
    required this.job,
    this.profile,
    required this.now,
    this.triggersNote,
    this.anacron = const [],
  });

  final JobEntry job;

  /// What stands for a timer's unread triggers: that they are being read,
  /// or why they were not; null for the listing's own words.
  final String? triggersNote;

  /// The monitoring clock's time when the details opened.
  final DateTime now;

  /// The probe's latest answer: the server's offset now and its systemd
  /// version.
  final HostProfile? profile;

  /// anacron's jobs (JOB-04), which word a directory's row when they
  /// drive it.
  final List<AnacronJob> anacron;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final job = this.job;
    final schedules = switch (job) {
      TimerJobEntry(triggers: null) => [
        triggersNote ?? l10n.jobsTimerTriggersUnread,
      ],
      _ => [for (final s in job.schedules) scheduleText(l10n, s)],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Semantics(
          header: true,
          child: Text(jobTitle(job), style: theme.textTheme.titleMedium),
        ),
        _Labelled(l10n.jobsColumnSource, [Text(sourceText(l10n, job))]),
        ...switch (job) {
          // The title is the line's command.
          CronJobEntry(:final job) => [
            _Labelled(l10n.jobsDetailsWritten, [Text(job.schedule)]),
            if (job.paused) _Run.note(l10n.jobsPausedDetail),
            if (job.managedBy case final manager?)
              _Run.note(l10n.jobsManagedDetail(manager.name)),
          ],
          TimerJobEntry(timer: SystemdTimer(:final activates?)) => [
            _Labelled(l10n.jobsDetailsStarts, [Text(activates)]),
          ],
          _ => const <Widget>[],
        },
        if (schedules.isNotEmpty)
          _Labelled(l10n.jobsColumnSchedule, [
            for (final schedule in schedules) Text(schedule),
          ]),
        Semantics(
          header: true,
          child: Text(
            l10n.jobsDetailsNextRuns,
            style: theme.textTheme.titleSmall,
          ),
        ),
        ...switch (job) {
          TimerJobEntry() => _timerRuns(l10n, job),
          _ => _cronRuns(l10n, job),
        },
      ],
    );
  }

  List<Widget> _cronRuns(AppLocalizations l10n, JobEntry job) {
    final (listed, unknown) = cronRuns(job);
    final runs = listed.where((run) => run.atUtc.isAfter(now)).toList();
    if (runs.isEmpty) {
      return [_Run(runsUnknownFor(l10n, job, anacron))];
    }
    return [
      for (final run in runs)
        _Run(runTimeText(l10n, run), note: runNote(l10n, run)),
    ];
  }

  /// The next elapse systemd listed, then each calendar trigger's elapses
  /// after [now] as the host's `systemd-analyze calendar` printed them, on
  /// the server's clock. Without those elapses the one run is all the app
  /// has, which a note says, so it never reads as the whole schedule.
  List<Widget> _timerRuns(AppLocalizations l10n, TimerJobEntry job) {
    final offset = profile?.serverZone?.offset ?? Duration.zero;
    final delay = job.randomizedDelay;
    final elapsesRead = (job.triggers ?? const []).any(
      (trigger) => trigger is CalendarSchedule && trigger.elapses != null,
    );
    return [
      _Run(switch (nextRunAfter(job, now)) {
        final next? => l10n.jobsRunTime(
          wallAt(next, offset),
          utcOffsetText(l10n, offset),
        ),
        null => l10n.chartUnknownValue,
      }, note: elapsesRead ? null : l10n.jobsTimerOneRun),
      for (final trigger in job.triggers ?? const <ScheduleDescription>[])
        if (trigger case CalendarSchedule(:final elapses?))
          _Labelled(scheduleText(l10n, trigger), [
            // A run the clock has passed since the reading drops out, as
            // the list-timers elapse does; one without an instant stays,
            // as nothing tells when it falls.
            ...switch (elapses.where((e) => e.atUtc?.isAfter(now) ?? true)) {
              Iterable(isEmpty: true) => [_Run(l10n.chartUnknownValue)],
              final ahead => [
                for (final elapse in ahead)
                  _Run(
                    elapse.text ??
                        switch (elapse.atUtc) {
                          final at? => l10n.jobsRunTime(
                            at,
                            utcOffsetText(l10n, Duration.zero),
                          ),
                          null => l10n.chartUnknownValue,
                        },
                  ),
              ],
            },
            if (listsOneElapse(profile)) _Run.note(l10n.jobsCalendarOneRun),
          ]),
      if (delay != null && delay > Duration.zero)
        _Run.note(l10n.jobsTimerRandomDelay(spanText(l10n, delay))),
    ];
  }
}

/// A job's last run (JOB-05), read once as its details open: a timer's
/// last trigger and how its service ended, or the newest start cron
/// logged for the line [cronCommand], as [cronUser] when it names one,
/// on the server's clock at [offset]. cron logs no exit status, which
/// the details say.
class JobLastRun extends StatefulWidget {
  const JobLastRun({
    super.key,
    required this.read,
    required this.offset,
    this.cronCommand,
    this.cronUser,
  });

  final Future<JobHistoryPayload> Function() read;
  final Duration? offset;

  /// A cron line's command, masked as the row shows it, and its user.
  final String? cronCommand;
  final String? cronUser;

  @override
  State<JobLastRun> createState() => _JobLastRunState();
}

class _JobLastRunState extends State<JobLastRun> {
  late final Future<JobHistoryPayload> _read = widget.read();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offset = widget.offset ?? Duration.zero;
    String at(DateTime time) =>
        l10n.jobsRunTime(wallAt(time, offset), utcOffsetText(l10n, offset));
    return FutureBuilder(
      future: _read,
      builder: (context, snapshot) =>
          _Labelled(l10n.jobsLastRun, switch (snapshot.data) {
            null => [_Run(l10n.jobsLastRunReading)],
            TimerLastRunPayload(lastRun: TimerLastRun(lastTrigger: null)) => [
              _Run(l10n.jobsLastRunNever),
            ],
            TimerLastRunPayload(:final lastRun) => [
              _Run(
                at(lastRun.lastTrigger!),
                note: switch (lastRun) {
                  TimerLastRun(result: 'success') => l10n.jobsLastRunSucceeded,
                  TimerLastRun(:final result?, :final exitStatus?) =>
                    l10n.jobsLastRunExited(result, exitStatus),
                  TimerLastRun(:final result?) => l10n.jobsLastRunEnded(result),
                  _ => null,
                },
              ),
            ],
            CronRunsPayload(:final runs) => switch (_newest(runs)) {
              final run? => [_Run(at(run.at), note: l10n.jobsLastRunNoStatus)],
              null => [_Run(l10n.jobsLastRunNotLogged(runs.length))],
            },
            JobHistoryFailed(:final failure) => [
              _Run(l10n.jobsLastRunFailed(failure.name)),
            ],
            _ => [_Run(l10n.chartUnknownValue)],
          }),
    );
  }

  /// The newest of [runs] that started [JobLastRun.cronCommand], both
  /// masked, as its user. The runs come newest first.
  LoggedCronRun? _newest(List<LoggedCronRun> runs) {
    final command = widget.cronCommand;
    if (command == null) return null;
    final user = widget.cronUser;
    return runs
        .where(
          (run) => run.command == command && (user == null || run.user == user),
        )
        .firstOrNull;
  }
}

/// A job's details in a sheet (03 §10.5: details push further), as of the
/// reading the row came from and the clock's time [now].
///
/// With [readTimer], a timer row whose triggers the listing does not carry
/// reads them when the sheet opens (JOB-02) and shows them once they come.
void showJobDetails(
  BuildContext context,
  JobEntry job,
  HostProfile? profile,
  DateTime now, {
  List<AnacronJob> anacron = const [],
  required Widget? Function(BuildContext context, JobEntry job) run,
  Widget? Function(BuildContext context, JobEntry job)? lastRun,
  Future<TimerDetailReport> Function(String unit)? readTimer,
}) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              switch ((job, readTimer)) {
                (TimerJobEntry(triggers: null), final read?) =>
                  _TimerDetailsLoader(
                    job: job as TimerJobEntry,
                    profile: profile,
                    now: now,
                    anacron: anacron,
                    read: read,
                  ),
                _ => JobDetails(
                  job: job,
                  profile: profile,
                  now: now,
                  anacron: anacron,
                ),
              },
              ?lastRun?.call(context, job),
              ?run(context, job),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A timer's [JobDetails] that reads its triggers once when it shows
/// (JOB-02, 03 §7.7): the row as listed meanwhile, with a note that the
/// read runs, then the row with what the read found, or the row and why
/// the read failed.
class _TimerDetailsLoader extends StatefulWidget {
  const _TimerDetailsLoader({
    required this.job,
    required this.profile,
    required this.now,
    required this.read,
    this.anacron = const [],
  });

  final TimerJobEntry job;
  final HostProfile? profile;
  final DateTime now;
  final List<AnacronJob> anacron;
  final Future<TimerDetailReport> Function(String unit) read;

  @override
  State<_TimerDetailsLoader> createState() => _TimerDetailsLoaderState();
}

class _TimerDetailsLoaderState extends State<_TimerDetailsLoader> {
  TimerDetailReport? _report;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.read(widget.job.timer.unit).then((report) {
        if (mounted) setState(() => _report = report);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = _report;
    final job = switch (report) {
      TimerDetailReport(:final detail?) => widget.job.withDetail(
        detail,
        calendars: report.calendars,
      ),
      _ => widget.job,
    };
    return JobDetails(
      job: job,
      profile: widget.profile,
      now: widget.now,
      anacron: widget.anacron,
      triggersNote: switch (report) {
        null => l10n.jobsTimerTriggersReading,
        TimerDetailReport(:final failure?) => timerDetailFailureText(
          l10n,
          failure,
        ),
        _ => null,
      },
    );
  }
}

/// Why a timer's triggers were not read, in words.
String timerDetailFailureText(
  AppLocalizations l10n,
  TimerDetailFailure failure,
) => switch (failure) {
  TimerDetailFailure.noLink => l10n.jobsTimerTriggersNoLink,
  TimerDetailFailure.invalidUnit ||
  TimerDetailFailure.missing ||
  TimerDetailFailure.unreadable => l10n.jobsTimerTriggersUnreadable,
  TimerDetailFailure.transport => l10n.jobsTimerTriggersFailed,
};

/// A label over its lines, read as one node; text wraps at any scale.
class _Labelled extends StatelessWidget {
  const _Labelled(this.label, this.children);

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// One run, or a note alone, with its note after an icon, so a DST change
/// or a random delay is never told by colour (A11Y-01); read as one node.
class _Run extends StatelessWidget {
  const _Run(String this.time, {this.note});

  const _Run.note(String this.note) : time = null;

  final String? time;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final time = this.time;
    final note = this.note;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          if (time != null) Text(time, style: theme.textTheme.bodyMedium),
          if (note != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Icon(Icons.info_outline, size: 16, color: muted),
                Expanded(
                  child: Text(
                    note,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

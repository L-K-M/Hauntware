import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart'
    show ActionEntry, ActionEntryPoint, OperationsScope, actionsAllowedAt;
import 'actions/cron_run_output.dart';
import 'admin_mode_chip.dart' show AdminScope;
import 'actions/host_actions.dart';
import 'actions/run_output_sheet.dart';
import 'edit/remote_editor.dart';
import 'freshness.dart';
import 'jobs_view.dart';
import 'server_surfaces.dart' show ServerPanel;
import 'sortable_table.dart';
import 'system_panel.dart' show PanelNotice;

/// The panel width from which the jobs table adds its source and schedule
/// columns, growing with the text scale as the other panels' does.
const double _wideWidth = 600;

/// The DST icon after a next run and the gap before it.
const double _dstIconSize = 14;
const double _dstIconGap = 4;

/// A table cell's horizontal padding, both sides: [SortableTable]'s.
const double _cellPadding = 16;

/// The share of its height the notices take before they scroll, so large
/// text never pushes the table out of sight.
const double _headerShare = 0.4;

/// When the list turns stale: twice the 60 s desktop and phone period of
/// `timers` and `cron` (03 §6.4). Cellular saver reads them once per
/// subscription, so this limit needs another look once the app sends
/// `SetCadenceProfile`.
const Duration _staleAfter = Duration(seconds: 120);

/// The probe's name for the `crontab` command (`kProbeTools`).
const String _crontabTool = 'crontab';

/// The jobs table's columns, whose names key them.
enum _Column { job, source, schedule, next }

/// Which jobs the panel lists: the cron and timers streams', or, in admin
/// mode, every other user's crontab (JOB-03).
enum _Source { mine, otherUsers }

/// What a source's reading said, which the empty list's ARB phrase
/// selects: it answered, gave no clear answer, or the server has no such
/// source.
enum _Answer { read, unread, absent }

/// The Jobs tab (03 §10.2, §7.7): JOB-01's unified list of the cron lines,
/// `cron.<period>` scripts and systemd timers, and JOB-02's schedules in
/// words with next runs on the server's clock.
///
/// It reads the `cron` and `timers` streams its [SampledSurface]
/// subscribes. Cron rows and their runs come from the engine, evaluated in
/// the server's zone (D58); a timer's row is its `systemctl list-timers`
/// entry, whose next elapse systemd computed. The rows of the last reading
/// of each stream stay under one freshness line in 9.5 item 4's words, and
/// a failed reading says why above them. A row opens its details: every
/// schedule, each run with its offset and DST note. Nothing animates
/// (A11Y-11); the clock ticks only while [visible], and the table follows
/// it only when its rows would change.
class JobsPanel extends StatefulWidget {
  const JobsPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Whether the panel's tab shows; see [SampledSurface.visible].
  final bool visible;

  @override
  State<JobsPanel> createState() => _JobsPanelState();
}

class _JobsPanelState extends State<JobsPanel> {
  /// What the panel listens to instead of the clock while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The table's order, which outlives tab switches: the workspace keeps a
  /// panel built once opened. The next job to run leads.
  TableSort? _sort = TableSort(_Column.next.name, TableSortDirection.ascending);

  _Source _source = _Source.mine;

  /// The last read of the other users' crontabs, and whether one runs.
  UserCrontabs? _others;
  bool _readingOthers = false;

  /// Whether admin mode is on for the server, which JOB-03 needs.
  bool _adminOn(BuildContext context) =>
      AdminScope.maybeOf(context)?.stateFor(widget.serverId)?.phase ==
      AdminModePhase.on;

  /// A desktop selection moves the panel to another server in place:
  /// the last one's crontabs, and a read still out for it, are not this
  /// one's.
  @override
  void didUpdateWidget(JobsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId) _forgetOthers();
  }

  void _forgetOthers() {
    _source = _Source.mine;
    _others = null;
    _readingOthers = false;
  }

  Future<void> _readOthers(BuildContext context) async {
    final admin = AdminScope.maybeOf(context);
    if (admin == null || _readingOthers) return;
    final serverId = widget.serverId;
    setState(() => _readingOthers = true);
    final read = await admin.readUserCrontabs(serverId);
    if (!mounted || serverId != widget.serverId) return;
    setState(() {
      _others = read;
      _readingOthers = false;
    });
  }

  /// The source switch, shown only in admin mode.
  Widget? _sourceSwitch(BuildContext context) {
    if (!_adminOn(context)) return null;
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SegmentedButton<_Source>(
        segments: [
          ButtonSegment(value: _Source.mine, label: Text(l10n.jobsSourceMine)),
          ButtonSegment(
            value: _Source.otherUsers,
            label: Text(l10n.jobsSourceOtherUsers),
          ),
        ],
        selected: {_source},
        onSelectionChanged: (choice) {
          setState(() => _source = choice.first);
          if (_source == _Source.otherUsers && _others == null) {
            unawaited(_readOthers(context));
          }
        },
      ),
    );
  }

  /// JOB-03's view: the other users' crontab lines, read-only, their
  /// commands masked by the engine (03 §8.9), with why any could not be
  /// read and a button to read them again. Nothing here acts.
  Widget _buildOthers(BuildContext context, HostProfile? profile) {
    final l10n = AppLocalizations.of(context);
    final read = _others;
    final now = widget.monitoring.clock.value;
    final jobs = read?.jobs ?? const <JobEntry>[];
    final notices = [
      ?_sourceSwitch(context),
      if (_readingOthers)
        PanelNotice(
          icon: Icons.hourglass_empty,
          text: l10n.jobsOtherUsersReading,
        ),
      if (read?.failure case final failure?)
        PanelNotice(
          icon: Icons.error_outline,
          text: l10n.jobsOtherUsersFailure(failure.name),
        ),
      if (read != null && read.unreadable.isNotEmpty)
        PanelNotice(
          icon: Icons.info_outline,
          text: l10n.jobsOtherUsersUnreadable(
            read.unreadable.join(l10n.fleetRowListSeparator),
          ),
        ),
      if (read != null && read.notRead > 0)
        PanelNotice(
          icon: Icons.info_outline,
          text: l10n.jobsOtherUsersNotRead(read.notRead),
        ),
      if (read != null && read.failure == null)
        PanelNotice(
          icon: Icons.visibility_off_outlined,
          text: l10n.jobsOtherUsersMasked,
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: _readingOthers ? null : () => _readOthers(context),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.jobsOtherUsersRefresh),
        ),
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        return Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: box.maxHeight * _headerShare,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: notices,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (read != null && read.failure == null)
                Expanded(
                  child: SortableTable<JobEntry>(
                    tableId: '${ServerPanel.jobs.name}.others',
                    columns: _columns(
                      context,
                      jobs,
                      wide: wide,
                      stale: false,
                      serverOffset: profile?.serverZone?.offset,
                      now: now,
                    ),
                    rows: jobs,
                    rowKey: (job) => job.id,
                    sort: _sort,
                    onSort: (sort) => setState(() => _sort = sort),
                    onRowActivated: (job) => _showDetails(
                      context,
                      job,
                      profile,
                      now,
                      run: (_, _) => null,
                    ),
                    empty: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(l10n.jobsOtherUsersEmpty),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// JOB-08's output sheet for [unit], the service a run started.
  void _showOutput(String unit) {
    if (!mounted) return;
    unawaited(
      showRunOutput(
        context,
        monitoring: widget.monitoring,
        serverId: widget.serverId,
        unit: unit,
      ),
    );
  }

  /// JOB-19's output sheet for the cron run [planId].
  void _showCronOutput(String planId, ActionPreview preview) {
    if (!mounted) return;
    final operations = OperationsScope.maybeOf(context);
    if (operations == null) return;
    unawaited(
      showCronRunOutput(
        context,
        operations: operations,
        serverId: widget.serverId,
        planId: planId,
        title: preview.targetName,
      ),
    );
  }

  /// The details' last run (JOB-05), read as they open: a timer's last
  /// trigger and result, or the newest start cron logged for a line that
  /// is not paused.
  Widget? _lastRun(BuildContext context, JobEntry job) {
    final reads = widget.monitoring.jobHistory;
    final serverId = widget.serverId;
    final offset = widget.monitoring
        .profileFor(serverId)
        .value
        ?.serverZone
        ?.offset;
    return switch (job) {
      TimerJobEntry(timer: SystemdTimer(:final unit, :final activates?)) =>
        JobLastRun(
          offset: offset,
          read: () => reads.read(
            serverId,
            TimerLastRunQuery(timer: unit, service: activates),
          ),
        ),
      CronJobEntry(:final job) when !job.paused => JobLastRun(
        offset: offset,
        cronCommand: job.command,
        cronUser: job.user,
        read: () => reads.read(serverId, const CronRunsQuery()),
      ),
      _ => null,
    };
  }

  /// The details' Run now, for a timer row, or a cron line no other
  /// manager owns, where actions are allowed.
  Widget? _runNow(BuildContext context, JobEntry job) => switch (job) {
    CronJobEntry(:final job) when job.managedBy == null => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        CronRunButton(
          serverId: widget.serverId,
          source: job.source,
          raw: job.raw,
          onRun: (planId, preview) {
            Navigator.of(context).pop();
            _showCronOutput(planId, preview);
          },
        ),
        // The details show the line as it was read, so they close first.
        CronPauseButton(
          serverId: widget.serverId,
          job: job,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              toggleCronPause(
                this.context,
                serverId: widget.serverId,
                job: job,
              ),
            );
          },
        ),
      ],
    ),
    TimerJobEntry(:final timer)
        when actionsAllowedAt(
          context,
          widget.serverId,
          ActionEntryPoint.timerRunNow,
        ) =>
      TimerRunButton(
        serverId: widget.serverId,
        timer: timer.unit,
        onRun: (unit) {
          Navigator.of(context).pop();
          _showOutput(unit);
        },
      ),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final monitoring = widget.monitoring;
    final serverId = widget.serverId;
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final cron = monitoring.sampleFor(serverId, SampleStream.cron);
    final timers = monitoring.sampleFor(serverId, SampleStream.timers);
    final cronReading = monitoring.lastReadingFor(serverId, SampleStream.cron);
    final timersReading = monitoring.lastReadingFor(
      serverId,
      SampleStream.timers,
    );
    final profile = monitoring.profileFor(serverId);
    final sampling = monitoring.samplingFor(serverId);
    // Admin mode that ended takes the other users' crontabs with it,
    // so turning it on again starts from the streams' rows.
    if (!_adminOn(context)) _forgetOthers();
    if (_source == _Source.otherUsers) {
      return ValueListenableBuilder(
        valueListenable: profile,
        builder: (context, profile, _) => _buildOthers(context, profile),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        cron,
        timers,
        cronReading,
        timersReading,
        profile,
        sampling,
      ]),
      builder: (context, _) => _build(
        context,
        latest: [cron.value, timers.value],
        readings: [?cronReading.value, ?timersReading.value],
        profile: profile.value,
        sampling: sampling.value,
      ),
    );
  }

  Widget _build(
    BuildContext context, {
    required List<Sample?> latest,
    required List<Sample> readings,
    required HostProfile? profile,
    required SamplingStatus? sampling,
  }) {
    final l10n = AppLocalizations.of(context);
    final clock = widget.monitoring.clock;
    // The list is as fresh as its older stream.
    final oldest = _earliest(readings.map((s) => s.at));
    final ticking = widget.visible && oldest != null;
    Freshness freshnessAt(DateTime now) => freshnessOf(
      now: now,
      staleAfter: _staleAfter,
      lastSampleAt: oldest,
      // No monitor set watches a server yet (FL-21): this panel samples it
      // while it shows.
      watched: false,
      sampling: sampling,
    );
    // lastReadingFor keeps only readings, each of its stream's variant.
    final cron = readings
        .map((s) => s.result)
        .whereType<CronResult>()
        .firstOrNull;
    final timers = readings
        .map((s) => s.result)
        .whereType<TimersResult>()
        .firstOrNull
        ?.timers;
    final serverOffset = profile?.serverZone?.offset;
    // Without systemd running the server has no timers, and a timers read
    // there fails for want of systemctl or its manager.
    final noTimers = profile?.systemdDir == false && timers == null;
    // The parser cannot tell an unclear `crontab -l` from a missing
    // command; the probe can, and without the command the login user has
    // no crontab to miss.
    final ownCrontab = switch (cron?.cron.ownCrontabPresent) {
      null when profile?.toolPresent(_crontabTool) == false => _Answer.absent,
      null => _Answer.unread,
      _ => _Answer.read,
    };
    final jobs = <JobEntry>[
      ...?cron?.jobs,
      for (final timer in timers?.timers ?? const <SystemdTimer>[])
        TimerJobEntry(timer: timer),
    ];
    final unavailable = [
      for (final sample in latest)
        if (sample case Sample(
          :final stream,
          result: final CollectorUnavailable result,
        ) when !(noTimers && stream == SampleStream.timers))
          PanelNotice(
            icon: result.reason == CollectorUnavailableReason.timeout
                ? Icons.timer_off_outlined
                : Icons.error_outline,
            text: l10n.jobsUnavailable(stream.name, result.reason.name),
            detail: result.detail,
          ),
    ];
    // Only both readings say the server has no job; an unread or failed
    // stream's notice stands above. An unclear `crontab -l` leaves the
    // user's own crontab out of the claim.
    final empty = cron == null || (timers == null && !noTimers)
        ? null
        : l10n.jobsEmpty(
            ownCrontab.name,
            (noTimers ? _Answer.absent : _Answer.read).name,
          );
    final timed = jobs.any(
      (job) => job is TimerJobEntry && job.timer.nextUtc != null,
    );
    final notices = [
      ?_sourceSwitch(context),
      if (oldest != null || freshnessAt(clock.value) is FreshnessPaused)
        ListenableBuilder(
          listenable: ticking ? clock : _silent,
          builder: (context, _) {
            final freshness = freshnessAt(clock.value);
            return PanelNotice(
              icon: freshness.stale ? Icons.history : Icons.schedule,
              text: freshnessText(l10n, freshness),
            );
          },
        ),
      ...unavailable,
      if (readings.isEmpty && unavailable.isEmpty)
        PanelNotice(icon: Icons.hourglass_empty, text: l10n.jobsWaiting),
      if (noTimers)
        PanelNotice(icon: Icons.info_outline, text: l10n.jobsNoSystemd),
      if (cron != null && ownCrontab == _Answer.unread)
        PanelNotice(icon: Icons.info_outline, text: l10n.jobsOwnCrontabUnknown),
      // JOB-04: the login user's crontab, wherever the command is.
      if (profile?.toolPresent(_crontabTool) == true)
        ActionEntry(
          serverId: widget.serverId,
          point: ActionEntryPoint.fileEdit,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => unawaited(
                openRemoteEditor(
                  context,
                  serverId: widget.serverId,
                  target: const CrontabTarget(),
                ),
              ),
              icon: const Icon(Icons.edit_calendar_outlined),
              label: Text(l10n.jobsEditOwnCrontab),
            ),
          ),
        ),
      ?_cronZone(l10n, cron, serverOffset),
      if (timed)
        PanelNotice(
          icon: Icons.public,
          text: serverOffset == null
              ? l10n.jobsTimerZoneUtc
              : l10n.jobsTimerZone(utcOffsetText(l10n, serverOffset)),
        ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        return Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: box.maxHeight * _headerShare,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: notices,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (readings.isNotEmpty)
                Expanded(
                  child: _ClockGate(
                    clock: clock,
                    ticking: ticking,
                    // The times turn stale, or a run they show passes.
                    dueAfter: (now) => _earliest([
                      if (!freshnessAt(now).stale) ?oldest?.add(_staleAfter),
                      for (final job in jobs) ?_nextAfter(job, now),
                    ]),
                    builder: (context, now) => SortableTable<JobEntry>(
                      tableId: ServerPanel.jobs.name,
                      columns: _columns(
                        context,
                        jobs,
                        wide: wide,
                        stale: freshnessAt(now).stale,
                        serverOffset: serverOffset,
                        now: now,
                      ),
                      rows: jobs,
                      rowKey: (job) => job.id,
                      sort: _sort,
                      onSort: (sort) => setState(() => _sort = sort),
                      // The table cuts commands and schedules short
                      // (A11Y-09); the details do not.
                      onRowActivated: (job) => _showDetails(
                        context,
                        job,
                        profile,
                        clock.value,
                        run: _runNow,
                        lastRun: _lastRun,
                        readTimer: (unit) => widget.monitoring.timerDetails
                            .read(widget.serverId, unit),
                      ),
                      // JOB-08 on timer rows and JOB-19 on cron lines no
                      // other manager owns, where actions are allowed (M4
                      // E21); the table keeps no slot otherwise.
                      rowActions:
                          actionsAllowedAt(
                            context,
                            widget.serverId,
                            ActionEntryPoint.timerRunNow,
                          )
                          ? (job) => switch (job) {
                              TimerJobEntry(:final timer) => timerActionEntries(
                                context,
                                serverId: widget.serverId,
                                timer: timer.unit,
                                onRun: _showOutput,
                              ),
                              CronJobEntry(:final job)
                                  when job.managedBy == null =>
                                [
                                  ...cronActionEntries(
                                    context,
                                    serverId: widget.serverId,
                                    source: job.source,
                                    raw: job.raw,
                                    onRun: _showCronOutput,
                                  ),
                                  ...cronPauseEntries(
                                    context,
                                    serverId: widget.serverId,
                                    job: job,
                                  ),
                                ],
                              _ => const [],
                            }
                          : null,
                      empty: empty == null
                          ? null
                          : Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(empty),
                            ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Builds its child as of the clock's time, and again only once the clock
/// reaches the instant [dueAfter] gives for that time, rather than on
/// every tick: the cron stream bounds the lines it evaluates, not those it
/// lists, so a long table is not sorted again every second.
class _ClockGate extends StatefulWidget {
  const _ClockGate({
    required this.clock,
    required this.ticking,
    required this.dueAfter,
    required this.builder,
  });

  final ValueListenable<DateTime> clock;

  /// Whether the clock may tick for it: the tab shows an age.
  final bool ticking;

  /// When the child built for a time changes next; null when it does not.
  final DateTime? Function(DateTime now) dueAfter;

  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<_ClockGate> createState() => _ClockGateState();
}

class _ClockGateState extends State<_ClockGate> {
  late DateTime _now;
  DateTime? _due;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _judge();
  }

  @override
  void didUpdateWidget(_ClockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_listening && oldWidget.clock != widget.clock) {
      oldWidget.clock.removeListener(_tick);
      _listening = false;
    }
    _judge();
  }

  @override
  void dispose() {
    if (_listening) widget.clock.removeListener(_tick);
    super.dispose();
  }

  /// Takes the clock's time, and listens to it only until a change is due.
  void _judge() {
    _now = widget.clock.value;
    _due = widget.dueAfter(_now);
    final listen = widget.ticking && _due != null;
    if (listen == _listening) return;

    if (listen) {
      widget.clock.addListener(_tick);
    } else {
      widget.clock.removeListener(_tick);
    }
    _listening = listen;
  }

  void _tick() {
    final due = _due;
    if (due == null || widget.clock.value.isBefore(due)) return;
    setState(_judge);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}

/// Which clock the cron rows' times follow (CN-02, D58): the server zone's
/// rules, or its offset now and why; nothing before the zone is known,
/// when each row says so.
PanelNotice? _cronZone(
  AppLocalizations l10n,
  CronResult? cron,
  Duration? serverOffset,
) {
  if (cron == null || cron.jobs.isEmpty) return null;

  final name = cron.zoneName;
  if (name != null) {
    return PanelNotice(icon: Icons.public, text: l10n.jobsZoneRules(name));
  }
  final fallback = cron.zoneFallback;
  if (fallback == null || serverOffset == null) return null;
  return PanelNotice(
    icon: Icons.public,
    text: l10n.jobsZoneFixed(utcOffsetText(l10n, serverOffset), fallback.name),
  );
}

/// The earliest of [instants], or null without one.
DateTime? _earliest(Iterable<DateTime> instants) =>
    instants.isEmpty ? null : instants.reduce((a, b) => a.isBefore(b) ? a : b);

/// The first of [job]'s cron runs after [now], so a run the clock has
/// passed since the reading never reads as next; null for a timer, and
/// once every listed run has passed.
CronRun? _cronRunAfter(JobEntry job, DateTime now) =>
    cronRuns(job).$1.where((run) => run.atUtc.isAfter(now)).firstOrNull;

/// When [job] runs next after [now]. systemd lists one elapse per timer,
/// so once the clock passes it the next one waits for the next reading.
DateTime? _nextAfter(JobEntry job, DateTime now) => switch (job) {
  TimerJobEntry(timer: SystemdTimer(:final nextUtc?))
      when nextUtc.isAfter(now) =>
    nextUtc,
  TimerJobEntry() => null,
  _ => _cronRunAfter(job, now)?.atUtc,
};

List<SortableTableColumn<JobEntry>> _columns(
  BuildContext context,
  List<JobEntry> jobs, {
  required bool wide,
  required bool stale,
  required Duration? serverOffset,
  required DateTime now,
}) {
  final l10n = AppLocalizations.of(context);
  ({String time, bool dst}) next(JobEntry job) =>
      _next(l10n, job, serverOffset, now);
  return [
    SortableTableColumn(
      id: _Column.job.name,
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
        id: _Column.source.name,
        label: l10n.jobsColumnSource,
        text: (job) => sourceText(l10n, job),
        sortKey: (job) => sourceText(l10n, job),
        extent: const FlexColumnExtent(2),
      ),
    if (wide)
      SortableTableColumn(
        id: _Column.schedule.name,
        label: l10n.jobsColumnSchedule,
        text: (job) => _scheduleCell(l10n, job),
        extent: const FlexColumnExtent(3),
      ),
    SortableTableColumn(
      id: _Column.next.name,
      label: l10n.jobsColumnNext,
      text: (job) => switch (next(job)) {
        (:final time, dst: true) => l10n.jobsNextRunDst(time),
        (:final time, dst: false) => time,
      },
      sortKey: (job) => _nextAfter(job, now),
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

/// A row's first schedule in words, why a cron row has none, or that a
/// timer's triggers are not read.
String _scheduleCell(AppLocalizations l10n, JobEntry job) {
  if (job case TimerJobEntry(triggers: null)) {
    return l10n.jobsTimerTriggersUnread;
  }
  if (job.schedules.firstOrNull case final schedule?) {
    return scheduleText(l10n, schedule);
  }
  final (_, unknown) = cronRuns(job);
  return unknown == null
      ? l10n.chartUnknownValue
      : runsUnknownText(l10n, unknown);
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
) {
  if (job is TimerJobEntry) {
    final offset = serverOffset ?? Duration.zero;
    final time = switch (_nextAfter(job, now)) {
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

/// A job's details in a sheet (03 §10.5: details push further), as of the
/// reading the row came from and the clock's time [now].
///
/// With [readTimer], a timer row whose triggers the listing does not carry
/// reads them when the sheet opens (JOB-02) and shows them once they come.
void _showDetails(
  BuildContext context,
  JobEntry job,
  HostProfile? profile,
  DateTime now, {
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
                    read: read,
                  ),
                _ => JobDetails(job: job, profile: profile, now: now),
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
  });

  final TimerJobEntry job;
  final HostProfile? profile;
  final DateTime now;
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
      return [
        _Run(
          unknown == null
              ? l10n.chartUnknownValue
              : runsUnknownText(l10n, unknown),
        ),
      ];
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
      _Run(switch (_nextAfter(job, now)) {
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

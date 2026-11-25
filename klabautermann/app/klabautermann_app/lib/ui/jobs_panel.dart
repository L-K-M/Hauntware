import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
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
import 'job_details.dart';
import 'jobs_table.dart';
import 'jobs_view.dart';
import 'panel_kit.dart';
import 'server_surfaces.dart' show ServerPanel;
import 'sortable_table.dart';

export 'job_details.dart';

/// The list's stale limit under [cadence], or null when the cellular
/// saver reads `cron` and `timers` only once per subscription, so no
/// newer reading is ever due: twice the shortest of their 03 §6.4
/// periods (60 s on desktop and phone), since a reading of either
/// stream refreshes the list.
Duration? _staleAfterFor(CadenceProfile cadence) => switch ((
  samplingPeriod(SampleStream.cron, cadence),
  samplingPeriod(SampleStream.timers, cadence),
)) {
  (null, null) => null,
  (final cron?, _) => cron * 2,
  (_, final timers?) => timers * 2,
};

/// The probe's name for the `crontab` command (`kProbeTools`).
const String _crontabTool = 'crontab';

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
  /// The table's order, which outlives tab switches: the workspace keeps a
  /// panel built once opened. The next job to run leads.
  TableSort? _sort = TableSort(
    JobsColumn.next.name,
    TableSortDirection.ascending,
  );

  _Source _source = _Source.mine;

  /// The last read of the other users' crontabs, and whether one runs.
  UserCrontabs? _others;
  bool _readingOthers = false;

  /// anacron's jobs (JOB-04), and why they could not be read; null
  /// before the read answers, which keeps the tab's shape until then.
  AnacronPayload? _anacron;
  JobHistoryFailed? _anacronFailure;
  bool _readingAnacron = false;

  /// The loaded anacron jobs, empty until the read answers.
  List<AnacronJob> get _anacronJobs => _anacron?.jobs ?? const [];

  /// Whether admin mode is on for the server, which JOB-03 needs.
  bool _adminOn(BuildContext context) =>
      AdminScope.maybeOf(context)?.stateFor(widget.serverId)?.phase ==
      AdminModePhase.on;

  /// A desktop selection moves the panel to another server in place:
  /// the last one's crontabs, and a read still out for it, are not this
  /// one's.
  @override
  void initState() {
    super.initState();
    // Only a shown tab reads, as the panel's sampled streams do.
    if (widget.visible) unawaited(_readAnacron());
  }

  @override
  void didUpdateWidget(JobsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId) {
      _forgetOthers();
      _forgetAnacron();
      if (widget.visible) unawaited(_readAnacron());
    } else if (widget.visible &&
        !oldWidget.visible &&
        _anacron == null &&
        _anacronFailure == null) {
      unawaited(_readAnacron());
    }
  }

  void _forgetOthers() {
    _source = _Source.mine;
    _others = null;
    _readingOthers = false;
  }

  /// A desktop selection moves to another server in place: its anacron
  /// table is not this one's, and a read still out for it is dropped.
  void _forgetAnacron() {
    _anacron = null;
    _anacronFailure = null;
    _readingAnacron = false;
  }

  /// Reads `/etc/anacrontab` for this server (JOB-04), as the login
  /// user. The first read shows nothing until it answers; [notify] tells
  /// a user-triggered retry to say that it runs.
  Future<void> _readAnacron({bool notify = false}) async {
    if (_readingAnacron) return;
    final serverId = widget.serverId;
    _readingAnacron = true;
    if (notify && mounted) setState(() {});
    final payload = await widget.monitoring.jobHistory.read(
      serverId,
      const AnacronQuery(),
    );
    if (!mounted || serverId != widget.serverId) return;
    setState(() {
      _readingAnacron = false;
      if (payload is AnacronPayload) {
        _anacron = payload;
        _anacronFailure = null;
      } else if (payload is JobHistoryFailed) {
        _anacron = null;
        _anacronFailure = payload;
      }
    });
  }

  /// JOB-04's states that need no list of their own: why the table
  /// could not be read, or that it holds nothing. Empty while the first
  /// read runs, so a tab with no answer yet keeps its shape.
  List<Widget> _anacronNotices(AppLocalizations l10n) {
    final jobs = _anacron?.jobs;
    if (jobs != null && jobs.isNotEmpty) return const [];
    if (_readingAnacron) {
      return [
        PanelNotice(icon: Icons.hourglass_empty, text: l10n.jobsAnacronReading),
      ];
    }
    if (jobs != null) {
      return [
        PanelNotice(icon: Icons.info_outline, text: l10n.jobsAnacronEmpty),
      ];
    }
    final failed = _anacronFailure;
    if (failed == null) return const [];
    if (failed.failure == JobHistoryFailure.notInstalled) {
      return [
        PanelNotice(
          icon: Icons.info_outline,
          text: l10n.jobsAnacronNotInstalled,
        ),
      ];
    }
    return [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.jobsAnacronFailed(failed.failure.name),
        detail: failed.detail,
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => unawaited(_readAnacron(notify: true)),
          icon: const Icon(Icons.refresh),
          label: Text(l10n.jobsAnacronRetry),
        ),
      ),
    ];
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
        final wide = panelIsWide(context, box);
        return Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: HeadedPanelBody(
            headerMaxHeight: box.maxHeight * kPanelHeaderShare,
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: notices,
            ),
            body: read != null && read.failure == null
                ? SortableTable<JobEntry>(
                    tableId: '${ServerPanel.jobs.name}.others',
                    columns: jobColumns(
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
                    onRowActivated: (job) => showJobDetails(
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
                  )
                : const SizedBox.shrink(),
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
    final staleAfter = _staleAfterFor(
      widget.monitoring.cadenceFor(widget.serverId),
    );
    Freshness freshnessAt(DateTime now) => freshnessOf(
      now: now,
      staleAfter: staleAfter,
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
          listenable: ticking ? clock : kSilentListenable,
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
      // JOB-04's states that take no list of their own: why the table
      // could not be read, or that it holds nothing.
      ..._anacronNotices(l10n),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        final wide = panelIsWide(context, box);
        return Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: HeadedPanelBody(
            headerMaxHeight: box.maxHeight * kPanelHeaderShare,
            header: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: notices,
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (readings.isNotEmpty)
                  Expanded(
                    flex: 3,
                    child: ClockGate(
                      clock: clock,
                      ticking: ticking,
                      // The times turn stale, or a run they show passes.
                      dueAfter: (now) => _earliest([
                        if (!freshnessAt(now).stale && staleAfter != null)
                          ?oldest?.add(staleAfter),
                        for (final job in jobs) ?nextRunAfter(job, now),
                      ]),
                      builder: (context, now) => SortableTable<JobEntry>(
                        tableId: ServerPanel.jobs.name,
                        columns: jobColumns(
                          context,
                          jobs,
                          wide: wide,
                          stale: freshnessAt(now).stale,
                          serverOffset: serverOffset,
                          now: now,
                          anacron: _anacronJobs,
                        ),
                        rows: jobs,
                        rowKey: (job) => job.id,
                        sort: _sort,
                        onSort: (sort) => setState(() => _sort = sort),
                        // The table cuts commands and schedules short
                        // (A11Y-09); the details do not.
                        onRowActivated: (job) => showJobDetails(
                          context,
                          job,
                          profile,
                          clock.value,
                          anacron: _anacronJobs,
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
                                TimerJobEntry(:final timer) =>
                                  timerActionEntries(
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
                // JOB-04: anacron's own table, under the jobs list. A
                // host without jobs keeps the list's full height and says
                // so in a notice instead.
                if (_anacron?.jobs.isNotEmpty ?? false) ...[
                  const Divider(height: 16),
                  Expanded(
                    flex: 2,
                    child: _AnacronSection(
                      jobs: _anacron!.jobs,
                      pending: _readingAnacron,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// anacron's periodic jobs (JOB-04): each job's period, delay, command
/// and last-run day. The section is built only when the table holds
/// jobs; its other states are notices above the table.
class _AnacronSection extends StatelessWidget {
  const _AnacronSection({required this.jobs, required this.pending});

  final List<AnacronJob> jobs;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l10n.jobsAnacronTitle, style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: pending
              ? Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _notice(
                    theme,
                    Icons.hourglass_empty,
                    l10n.jobsAnacronReading,
                  ),
                )
              : ListView.separated(
                  itemCount: jobs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _job(context, l10n, theme, jobs[index]),
                ),
        ),
      ],
    );
  }

  Widget _job(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    AnacronJob job,
  ) {
    Widget fact(String label, String value) => MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // Large text wraps the value within the row instead of
          // overflowing it.
          Flexible(
            child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // One node per job: a screen reader hears its name, command and
      // facts together.
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(job.identifier, style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              job.command,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                fact(
                  l10n.jobsAnacronLabelPeriod,
                  anacronPeriodText(l10n, job.period),
                ),
                fact(
                  l10n.jobsAnacronLabelDelay,
                  anacronDelayText(l10n, job.delayMinutes),
                ),
                fact(
                  l10n.jobsAnacronLabelLastRun,
                  anacronLastRunText(l10n, job.lastRun),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice(
    ThemeData theme,
    IconData icon,
    String text, [
    String? detail,
  ]) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(text),
            if (detail != null && detail.isNotEmpty)
              Text(
                detail,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    ],
  );
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

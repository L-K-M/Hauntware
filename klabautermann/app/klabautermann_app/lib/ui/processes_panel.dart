import 'dart:async' show Timer, unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import 'actions/host_actions.dart';
import 'freshness.dart';
import 'process_detail_view.dart';
import 'processes_view.dart';
import 'sortable_table.dart';
import 'time_display.dart';

/// The panel width from which the processes show as the sortable table;
/// narrower, as on a phone, they show as a list of two-line rows rather
/// than a squeezed table. It grows with the text scale, as the table's
/// columns do.
const double _wideWidth = 600;

/// The share of its height the header takes before it scrolls, so large
/// text never pushes the list out of sight.
const double _headerShare = 0.4;

/// How old a `procs` reading grows before it reads as stale: twice the
/// stream's slowest cadence in 03 §6.4 (10 s, Cellular saver), the rule
/// `kFleetRowStaleAfter` keeps for the fleet's streams.
const Duration _staleAfter = Duration(seconds: 20);

/// How long a revealed argument shows before it is masked again (SAF-07:
/// a reveal is temporary).
const Duration kRevealDuration = Duration(seconds: 30);

/// The Processes tab (03 §10.4, PRC-01): the server's processes by CPU,
/// memory, user, start time and command, with a filter, "showing N of M"
/// when the host left processes out (D48), and each argument masked per
/// 03 §8.9 until revealed in a process's details.
///
/// It reads the `procs` stream its [SampledSurface] subscribes, keeping
/// the last good list while a reading fails, under one freshness line in
/// 9.5 item 4's words; stale values turn grey. What the host did not
/// report reads "unknown". The clock ticks only while [visible] and only
/// the freshness line and the grey follow it. Where actions are allowed,
/// the table's row-action slot and a process's details offer PRC-02's
/// signals.
class ProcessesPanel extends StatefulWidget {
  const ProcessesPanel({
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
  State<ProcessesPanel> createState() => _ProcessesPanelState();
}

class _ProcessesPanelState extends State<ProcessesPanel> {
  /// What the clock's listeners hear instead while nothing ages.
  static final Listenable _silent = Listenable.merge(const []);

  /// The order and filter, which outlive tab switches: the workspace keeps
  /// a panel built once opened. The busiest processes lead, as in top.
  TableSort _sort = TableSort(
    ProcessColumn.cpu.name,
    TableSortDirection.descending,
  );
  final _filter = TextEditingController();

  /// Whether the rows show as PRC-03's tree, children under their parent
  /// in the sort's order, rather than one sorted list.
  bool _tree = false;

  @override
  void didUpdateWidget(ProcessesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another server's processes answer to another query.
    if (widget.serverId != oldWidget.serverId) _filter.clear();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final monitoring = widget.monitoring;
    final latest = monitoring.sampleFor(widget.serverId, SampleStream.procs);
    final reading = monitoring.lastReadingFor(
      widget.serverId,
      SampleStream.procs,
    );
    final sampling = monitoring.samplingFor(widget.serverId);
    final profile = monitoring.profileFor(widget.serverId);
    return ListenableBuilder(
      listenable: Listenable.merge([latest, reading, sampling, profile]),
      builder: (context, _) => _build(
        context,
        latest.value,
        reading.value,
        sampling.value,
        profile.value,
      ),
    );
  }

  Freshness _freshness(Sample? reading, SamplingStatus? sampling) =>
      _freshnessAt(widget.monitoring.clock.value, reading, sampling);

  Widget _build(
    BuildContext context,
    Sample? latest,
    Sample? reading,
    SamplingStatus? sampling,
    HostProfile? profile,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final clock = widget.visible && reading != null
        ? widget.monitoring.clock
        : _silent;
    final unavailable = switch (latest?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final result = switch (reading?.result) {
      final ProcsResult result => result,
      _ => null,
    };
    final leftOut = result == null ? null : processesLeftOut(result);
    final flagCounts = result == null
        ? const <ProcessFlag, int>{}
        : processFlagCounts(result.processes);
    final freshness = _freshness(reading, sampling);

    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (reading != null || freshness is FreshnessPaused)
              ListenableBuilder(
                listenable: clock,
                builder: (context, _) {
                  final now = _freshness(reading, sampling);
                  return _Notice(
                    icon: now.stale ? Icons.history : Icons.schedule,
                    text: freshnessText(l10n, now),
                  );
                },
              ),
            if (unavailable != null)
              _Notice(
                icon: unavailable.reason == CollectorUnavailableReason.timeout
                    ? Icons.timer_off_outlined
                    : Icons.error_outline,
                text: l10n.processesUnavailable(unavailable.reason.name),
                detail: unavailable.detail,
              )
            else if (result == null)
              _Notice(icon: Icons.hourglass_empty, text: l10n.processesWaiting),
            if (leftOut != null)
              _Notice(
                icon: Icons.filter_alt_outlined,
                text: switch (leftOut.total) {
                  final total? => l10n.processesShownOf(leftOut.shown, total),
                  null => l10n.processesShownSome(leftOut.shown),
                },
              ),
            if (flagCounts.isNotEmpty)
              _Notice(
                icon: Icons.warning_amber,
                text: [
                  for (final MapEntry(:key, :value) in flagCounts.entries)
                    l10n.processesFlagCount(key.name, value),
                ].join(l10n.processesFlagSeparator),
              ),
            if (result != null) _filterField(l10n),
            if (result != null)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: Text(l10n.processesTree),
                    selected: _tree,
                    onSelected: (tree) => setState(() => _tree = tree),
                  ),
                  if (!wide) _sortControls(l10n),
                ],
              ),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (result == null || reading == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        // Filled below in tree mode; the command cell indents by it.
        final depths = <int, int>{};
        final columns = _columns(
          l10n,
          profile,
          reading.at,
          shown: (at) => displayTime(context, widget.serverId, at),
          depths: depths,
        );
        final user = columns.firstWhere(
          (column) => column.id == ProcessColumn.user.name,
        );
        final matches = filterProcesses(
          result.processes,
          _filter.text,
          user.text,
        );
        final List<ProcessRow> rows;
        if (_tree) {
          // Siblings keep the sort's order; a filter keeps each match's
          // ancestors so it stays in place.
          final kept = _filter.text.trim().isEmpty || matches.isEmpty
              ? matches
              : withAncestors(matches, result.processes);
          final tree = processTree(sortTableRows(kept, columns, _sort));
          rows = [for (final entry in tree) entry.row];
          for (final entry in tree) {
            depths[entry.row.pid] = entry.depth;
          }
        } else {
          rows = matches;
        }
        final empty = Text(
          _filter.text.trim().isEmpty
              ? l10n.processesEmpty
              : l10n.processesNoMatch,
        );
        void open(ProcessRow row) => _showProcess(
          context,
          row,
          columns,
          monitoring: widget.monitoring,
          serverId: widget.serverId,
          reading: reading,
          clock: widget.monitoring.clock,
          sampling: widget.monitoring.samplingFor(widget.serverId),
        );
        final body = wide
            ? SortableTable<ProcessRow>(
                tableId: SampleStream.procs.name,
                columns: columns,
                rows: rows,
                rowKey: (row) => row.pid,
                // The tree is already in order; a header still picks the
                // order of siblings.
                sort: _tree ? null : _sort,
                onSort: (sort) => setState(() => _sort = sort),
                onRowActivated: open,
                // PRC-02's signals, where actions are allowed (M4 E21).
                rowActions: (row) => processActionEntries(
                  context,
                  serverId: widget.serverId,
                  row: row,
                ),
                empty: Padding(padding: const EdgeInsets.all(16), child: empty),
              )
            : _list(rows, columns, empty, open, depths);
        // Values grey once stale (03 §9.5 item 4); the list keeps its place
        // in the tree as they do.
        final greyed = theme.copyWith(
          textTheme: theme.textTheme.apply(
            bodyColor: theme.colorScheme.onSurfaceVariant,
            displayColor: theme.colorScheme.onSurfaceVariant,
          ),
        );
        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _headerShare,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListenableBuilder(
                    listenable: clock,
                    child: body,
                    builder: (context, body) => Theme(
                      data: _freshness(reading, sampling).stale
                          ? greyed
                          : theme,
                      child: body!,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _filterField(AppLocalizations l10n) => TextField(
    controller: _filter,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      prefixIcon: const Icon(Icons.search),
      hintText: l10n.processesFilterHint,
      suffixIcon: _filter.text.isEmpty
          ? null
          : IconButton(
              tooltip: l10n.processesFilterClear,
              icon: const Icon(Icons.clear),
              onPressed: () => setState(_filter.clear),
            ),
    ),
  );

  /// The phone layout's order: the table's columns in a menu, and the
  /// direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = ProcessColumn.values.byName(_sort.columnId);
    final ascending = _sort.direction == TableSortDirection.ascending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.processesSortBy,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        DropdownButton<ProcessColumn>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in ProcessColumn.values)
              DropdownMenuItem(
                value: choice,
                child: Text(_label(l10n, choice)),
              ),
          ],
          onChanged: (choice) {
            if (choice == null) return;
            setState(
              () => _sort = TableSort(
                choice.name,
                _firstDirection.contains(choice)
                    ? TableSortDirection.descending
                    : TableSortDirection.ascending,
              ),
            );
          },
        ),
        IconButton(
          tooltip: ascending
              ? l10n.tableSortedAscending
              : l10n.tableSortedDescending,
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
          onPressed: () => setState(
            () => _sort = TableSort(
              _sort.columnId,
              ascending
                  ? TableSortDirection.descending
                  : TableSortDirection.ascending,
            ),
          ),
        ),
      ],
    );
  }

  /// The phone layout: two-line rows that wrap at large text, in the
  /// table's order, each one node naming its cells as the table's rows do.
  Widget _list(
    List<ProcessRow> rows,
    List<SortableTableColumn<ProcessRow>> columns,
    Widget empty,
    ValueChanged<ProcessRow> open,
    Map<int, int> depths,
  ) {
    if (rows.isEmpty) return empty;

    final sorted = _tree ? rows : sortTableRows(rows, columns, _sort);
    final l10n = AppLocalizations.of(context);
    return ListView.separated(
      itemCount: sorted.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = sorted[index];
        return Semantics(
          key: ValueKey('${SampleStream.procs.name}.row.${row.pid}'),
          container: true,
          button: true,
          label: [
            for (final column in columns)
              l10n.tableCellSemantics(column.label, column.text(row)),
          ].join('\n'),
          excludeSemantics: true,
          onTap: () => open(row),
          child: InkWell(
            onTap: () => open(row),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  _CommandText(
                    row: row,
                    maxLines: 2,
                    depth: depths[row.pid] ?? 0,
                  ),
                  Wrap(
                    spacing: 16,
                    runSpacing: 2,
                    children: [
                      for (final column in columns.skip(1))
                        Text(
                          l10n.processesFact(column.label, column.text(row)),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Freshness _freshnessAt(
  DateTime now,
  Sample? reading,
  SamplingStatus? sampling,
) => freshnessOf(
  now: now,
  staleAfter: _staleAfter,
  lastSampleAt: reading?.at,
  // No monitor set watches a server yet (FL-21): the panel samples it
  // while it shows.
  watched: false,
  sampling: sampling,
);

/// The columns whose largest values matter, which start descending.
const _firstDirection = {ProcessColumn.cpu, ProcessColumn.memory};

String _label(AppLocalizations l10n, ProcessColumn column) => switch (column) {
  ProcessColumn.command => l10n.processesColumnCommand,
  ProcessColumn.pid => l10n.processesColumnPid,
  ProcessColumn.user => l10n.processesColumnUser,
  ProcessColumn.cpu => l10n.processesColumnCpu,
  ProcessColumn.memory => l10n.processesColumnMemory,
  ProcessColumn.started => l10n.processesColumnStarted,
};

/// The table's columns, which the phone list sorts and words by too. A
/// start on the day of the reading taken [at] shows its time, an earlier
/// one its date, both as [shown] gives a server time for the time display
/// (A11Y-07). Unknown values sort last (SortableTable).
List<SortableTableColumn<ProcessRow>> _columns(
  AppLocalizations l10n,
  HostProfile? profile,
  DateTime at, {
  required DateTime Function(DateTime at) shown,
  Map<int, int> depths = const {},
}) {
  final unknown = l10n.chartUnknownValue;
  final day = shown(at);
  String started(DateTime? startedAt) {
    if (startedAt == null) return unknown;

    final local = shown(startedAt);
    final today =
        local.year == day.year &&
        local.month == day.month &&
        local.day == day.day;
    return today
        ? l10n.processesStartedTime(local)
        : l10n.processesStartedDate(local);
  }

  SortableTableColumn<ProcessRow> column(
    ProcessColumn id,
    String Function(ProcessRow row) text,
    Comparable<Object>? Function(ProcessRow row) sortKey, {
    ColumnExtent extent = const FixedColumnExtent(88),
    CellAlignment alignment = CellAlignment.end,
    Widget Function(BuildContext context, ProcessRow row)? cell,
  }) => SortableTableColumn(
    id: id.name,
    label: _label(l10n, id),
    text: text,
    sortKey: sortKey,
    firstDirection: _firstDirection.contains(id)
        ? TableSortDirection.descending
        : TableSortDirection.ascending,
    extent: extent,
    alignment: alignment,
    cell: cell,
  );

  return [
    column(
      ProcessColumn.command,
      (row) => _commandText(l10n, row, spoken: true),
      // Shown text only: a sort by secrets would hint at them (03 §8.9).
      (row) => (commandLineText(row) ?? row.name)?.toLowerCase(),
      extent: const FlexColumnExtent(3),
      alignment: CellAlignment.start,
      cell: (context, row) =>
          _CommandText(row: row, depth: depths[row.pid] ?? 0),
    ),
    column(
      ProcessColumn.pid,
      (row) => row.pid.toString(),
      (row) => row.pid,
      extent: const FixedColumnExtent(64),
    ),
    column(
      ProcessColumn.user,
      (row) => switch ((processUserName(row, profile), row.uid)) {
        (final name?, _) => name,
        (null, final uid?) => l10n.processesUid(uid),
        (null, null) => unknown,
      },
      (row) => processUserSortKey(row, profile),
      extent: const FixedColumnExtent(104),
      alignment: CellAlignment.start,
    ),
    column(
      ProcessColumn.cpu,
      (row) => switch (row.cpuPercent) {
        final cpu? => l10n.processesCpu(cpu / 100),
        null => unknown,
      },
      (row) => row.cpuPercent,
      extent: const FixedColumnExtent(72),
    ),
    column(
      ProcessColumn.memory,
      (row) => switch (row.residentBytes) {
        // IEC units (03 §10.10).
        final bytes? => ghostFormatBinarySize(bytes),
        null => unknown,
      },
      (row) => row.residentBytes,
    ),
    column(
      ProcessColumn.started,
      (row) => started(row.startedAt),
      // Ticks after boot order the starts even where their time is
      // unknown.
      (row) => row.startTicks,
      extent: const FixedColumnExtent(104),
    ),
  ];
}

/// [row]'s command line, or its kernel name where the host gave none; a
/// [spoken] one says "(masked)" where the screen shows the mask.
String _commandText(
  AppLocalizations l10n,
  ProcessRow row, {
  bool spoken = false,
}) {
  final line = commandLineText(
    row,
    maskWord: spoken ? l10n.processesMasked : null,
  );
  if (line != null) return line;

  final name = row.name;
  return name == null
      ? l10n.processesCommandUnavailable
      : l10n.processesCommandUnavailableOf(name);
}

/// A row's command line; one the host did not give reads so beside an
/// icon, so it is told apart without colour (A11Y-01). The table reads
/// the spoken text instead.
class _CommandText extends StatelessWidget {
  const _CommandText({required this.row, this.maxLines = 1, this.depth = 0});

  final ProcessRow row;
  final int maxLines;

  /// Parents above the row in PRC-03's tree; 0 outside it.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final flag = processFlag(row);
    final text = Text(
      _commandText(l10n, row),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      softWrap: maxLines > 1,
      style: theme.textTheme.bodyMedium,
    );
    final line = commandLineText(row) != null && flag == null
        ? text
        : Row(
            spacing: 4,
            children: [
              if (commandLineText(row) == null)
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              // PRC-06: the state in words beside its colour (A11Y-01).
              if (flag != null) _FlagBadge(flag: flag),
              Flexible(child: text),
            ],
          );
    if (depth == 0) return line;

    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: _treeIndent * depth.clamp(0, kProcessTreeDepthShown),
      ),
      child: line,
    );
  }
}

/// How far each tree level indents a command.
const double _treeIndent = 12;

/// PRC-06's word for a flagged run state, in the error container's
/// colours.
class _FlagBadge extends StatelessWidget {
  const _FlagBadge({required this.flag});

  final ProcessFlag flag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          AppLocalizations.of(context).processesFlag(flag.name),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

/// [row]'s details in a sheet, as read: its figures in [columns]' words,
/// its parent and state, and each argument, a masked one revealed only on
/// a tap there (03 §8.9). The sheet keeps that [reading], so it says the
/// reading's freshness by [clock] and the server's [sampling] as it
/// changes, and greys its figures once stale.
void _showProcess(
  BuildContext context,
  ProcessRow row,
  List<SortableTableColumn<ProcessRow>> columns, {
  required MonitoringController monitoring,
  required String serverId,
  required Sample reading,
  required ValueListenable<DateTime> clock,
  required ValueListenable<SamplingStatus?> sampling,
}) {
  final l10n = AppLocalizations.of(context);
  final unknown = l10n.chartUnknownValue;
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ProcessSheet(
        monitoring: monitoring,
        serverId: serverId,
        row: row,
        reading: reading,
        clock: clock,
        sampling: sampling,
        facts: [
          for (final column in columns.skip(1))
            (column.label, column.text(row)),
          (l10n.processesParentPid, row.parentPid?.toString() ?? unknown),
          (l10n.processesState, row.state ?? unknown),
        ],
      ),
    ),
  );
}

/// A process's details: the reading's facts, then PRC-04 and PRC-05's
/// read of the process itself, which the sheet asks for when it opens and
/// on request, then its arguments and environment. Revealed arguments and
/// variables live in this sheet only: each is masked again after
/// [kRevealDuration], when the app turns inactive, and when the sheet
/// closes, and nothing sends, stores or logs them (SAF-07). Inactive
/// precedes hidden on the way to the background, while a frame can still
/// draw the mask before an app switcher's snapshot.
class _ProcessSheet extends StatefulWidget {
  const _ProcessSheet({
    required this.monitoring,
    required this.serverId,
    required this.row,
    required this.facts,
    required this.reading,
    required this.clock,
    required this.sampling,
  });

  final MonitoringController monitoring;
  final String serverId;
  final ProcessRow row;
  final List<(String, String)> facts;
  final Sample reading;
  final ValueListenable<DateTime> clock;
  final ValueListenable<SamplingStatus?> sampling;

  @override
  State<_ProcessSheet> createState() => _ProcessSheetState();
}

class _ProcessSheetState extends State<_ProcessSheet> {
  /// The revealed arguments and variables by kind and index, each with
  /// the timer that masks it.
  final Map<_Revealed, Timer> _revealed = {};
  late final AppLifecycleListener _lifecycle;

  /// The process read's answer, null while it reads.
  HostPayload? _detail;
  bool _reading = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _maskAll);
    if (widget.row.startTicks != null) unawaited(_read());
  }

  Future<void> _read() async {
    final ticks = widget.row.startTicks;
    if (ticks == null) return;

    final ticket = ++_ticket;
    setState(() => _reading = true);
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      ProcessDetailQuery(pid: widget.row.pid, startTicks: ticks),
    );
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _detail = result.payload;
      _reading = false;
      // A new read can list other variables at the same places.
      _revealed.removeWhere((key, timer) {
        if (key.$1 != _MaskedKind.variable) return false;
        timer.cancel();
        return true;
      });
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final timer in _revealed.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _toggle(_Revealed key) {
    final timer = _revealed.remove(key);
    setState(() {
      if (timer != null) {
        timer.cancel();
        return;
      }
      _revealed[key] = Timer(kRevealDuration, () {
        if (mounted) setState(() => _revealed.remove(key));
      });
    });
  }

  void _maskAll() {
    if (_revealed.isEmpty) return;

    setState(() {
      for (final timer in _revealed.values) {
        timer.cancel();
      }
      _revealed.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final row = widget.row;
    final arguments = row.arguments ?? const <MaskedValue>[];
    final header = <Widget>[
      Semantics(
        header: true,
        child: Text(
          row.name ?? row.pid.toString(),
          style: theme.textTheme.titleMedium,
        ),
      ),
      // Only where actions show, so the sheet keeps its layout otherwise.
      if (actionsAllowedAt(
        context,
        widget.serverId,
        ActionEntryPoint.processSignal,
      ))
        ProcessActionButtons(serverId: widget.serverId, row: row),
      ListenableBuilder(
        listenable: Listenable.merge([widget.clock, widget.sampling]),
        builder: (context, _) {
          final freshness = _freshnessAt(
            widget.clock.value,
            widget.reading,
            widget.sampling.value,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              _Notice(
                icon: freshness.stale ? Icons.history : Icons.schedule,
                text: freshnessText(l10n, freshness),
              ),
              // Grey once stale (03 §9.5 item 4).
              _Facts(facts: widget.facts, muted: freshness.stale),
            ],
          );
        },
      ),
      ..._detailLines(l10n),
      Semantics(
        header: true,
        child: Text(
          l10n.processesCommandLineTitle,
          style: theme.textTheme.titleSmall,
        ),
      ),
      if (arguments.isEmpty)
        _Notice(
          icon: Icons.info_outline,
          text: l10n.processesCommandUnavailable,
        )
      else if (arguments.any((argument) => argument.isMasked))
        Text(
          l10n.processesRevealNote(kRevealDuration.inSeconds),
          style: theme.textTheme.bodySmall,
        ),
    ];
    final details = _detail;
    final variables = details is ProcessDetails
        ? details.environment ?? const <EnvVar>[]
        : const <EnvVar>[];
    final environment = <Widget>[
      if (details case ProcessDetails(:final detail, :final environment)) ...[
        Semantics(
          header: true,
          child: Text(
            l10n.processesEnvironmentTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (detail.environmentDenied)
          _Notice(
            icon: Icons.lock_outline,
            text: l10n.processesEnvironmentDenied,
          )
        else if (environment == null || environment.isEmpty)
          _Notice(icon: Icons.info_outline, text: l10n.processesEnvironmentNone)
        else if (environment.length >= kProcessEnvironLimit)
          Text(
            l10n.processesEnvironmentCapped(kProcessEnvironLimit),
            style: theme.textTheme.bodySmall,
          ),
      ],
    ];
    final variablesAt = header.length + arguments.length + environment.length;
    // Built lazily: a command line can hold thousands of arguments.
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: variablesAt + variables.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: index < header.length
              ? header[index]
              : index < header.length + arguments.length
              ? _masked(l10n, (
                  _MaskedKind.argument,
                  index - header.length,
                ), arguments[index - header.length])
              : index < variablesAt
              ? environment[index - header.length - arguments.length]
              : _variable(l10n, index - variablesAt, variables),
        ),
      ),
    );
  }

  /// PRC-04 and PRC-05's lines: what the process read found, or why it
  /// found nothing, and the way to read it again.
  List<Widget> _detailLines(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final canRead = widget.row.startTicks != null;
    final status = switch (_detail) {
      _ when !canRead => _Notice(
        icon: Icons.info_outline,
        text: l10n.processesDetailNoStart,
      ),
      null => _Notice(
        icon: Icons.hourglass_empty,
        text: l10n.processesDetailReading,
      ),
      ProcessDetails(:final detail) => _Facts(
        facts: processDetailFacts(
          l10n,
          detail,
          unknown: l10n.chartUnknownValue,
        ),
      ),
      ProcessEnded(:final end) => _Notice(
        icon: Icons.history,
        text: l10n.processesDetailEnded(end.name),
      ),
      HostQueryFailed(:final failure, :final detail) => _Notice(
        icon: Icons.error_outline,
        text: l10n.processesDetailFailed(failure.name),
        detail: detail,
      ),
      _ => _Notice(
        icon: Icons.error_outline,
        text: l10n.processesDetailFailed(HostQueryFailure.failed.name),
      ),
    };
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.processesDetailTitle,
          style: theme.textTheme.titleSmall,
        ),
      ),
      status,
      if (canRead)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_read()),
            child: Text(l10n.processesDetailReadAgain),
          ),
        ),
    ];
  }

  /// One environment variable, its name above its value, which is masked
  /// by key (03 §8.9) until revealed.
  Widget _variable(AppLocalizations l10n, int index, List<EnvVar> variables) {
    final variable = variables[index];
    return _masked(
      l10n,
      (_MaskedKind.variable, index),
      variable.value,
      name: variable.name,
    );
  }

  /// [value] under its [name], if any, shown as is or, when masked,
  /// revealed for a while on a tap.
  Widget _masked(
    AppLocalizations l10n,
    _Revealed key,
    MaskedValue value, {
    String? name,
  }) {
    final theme = Theme.of(context);
    Widget named(Widget value) => name == null
        ? value
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              value,
            ],
          );
    if (!value.isMasked) {
      return MergeSemantics(child: named(Text(clipProcessText(value.display))));
    }

    final revealed = _revealed.containsKey(key);
    final shown = clipProcessText(revealed ? value.reveal()! : value.display);
    // A masked value is read as masked, never as eight asterisks.
    final spoken = revealed
        ? shown
        : clipProcessText(argumentText(value, maskWord: l10n.processesMasked));
    return Semantics(
      button: true,
      // A masked value is read as masked, never as eight asterisks.
      label: name == null
          ? spoken
          : l10n.processesEnvironmentEntry(name, spoken),
      hint: revealed ? l10n.processesHideHint : l10n.processesRevealHint,
      excludeSemantics: true,
      onTap: () => _toggle(key),
      child: InkWell(
        onTap: () => _toggle(key),
        child: ConstrainedBox(
          // A touch needs a 48 dp target (A11Y-01); a pointer, the line.
          constraints: BoxConstraints(
            minHeight: ghostIsDesktopPlatform(Theme.of(context).platform)
                ? 0
                : kMinInteractiveDimension,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                Expanded(child: named(Text(shown))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a revealed value is in a process's details.
enum _MaskedKind { argument, variable }

/// A revealed value's key: its kind and its index among that kind.
typedef _Revealed = (_MaskedKind, int);

/// Labelled values in a wrapping row, each label and value read as one
/// node; [muted] greys the values, as for a stale reading.
class _Facts extends StatelessWidget {
  const _Facts({required this.facts, this.muted = false});

  final List<(String, String)> facts;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: muted ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A state in words beside an icon, read as one node; the icon adds a
/// shape, the text carries the meaning (A11Y-01). [detail] is the host's
/// error output, never translated.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.detail});

  final IconData icon;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: muted),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                if (detail != null && detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

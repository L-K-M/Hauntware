import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/host_actions.dart';
import 'freshness.dart';
import 'panel_kit.dart';
import 'process_sheet.dart';
import 'processes_view.dart';
import 'sortable_table.dart';
import 'time_display.dart';

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
  /// The order and filter, which outlive tab switches: the workspace keeps
  /// a panel built once opened. The busiest processes lead, as in top.
  TableSort _sort = TableSort(
    ProcessColumn.cpu.name,
    TableSortDirection.descending,
  );
  final _filter = TextEditingController();

  /// The filter field, which `/` in the table focuses (PLT-06).
  final _filterFocus = FocusNode();

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
    _filterFocus.dispose();
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
      processesFreshnessAt(widget.monitoring.clock.value, reading, sampling);

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
        : kSilentListenable;
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
        final wide = panelIsWide(context, box);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (reading != null || freshness is FreshnessPaused)
              ListenableBuilder(
                listenable: clock,
                builder: (context, _) {
                  final now = _freshness(reading, sampling);
                  return PanelNotice.state(
                    icon: now.stale ? Icons.history : Icons.schedule,
                    text: freshnessText(l10n, now),
                  );
                },
              ),
            if (unavailable != null)
              PanelNotice.state(
                icon: unavailable.reason == CollectorUnavailableReason.timeout
                    ? Icons.timer_off_outlined
                    : Icons.error_outline,
                text: l10n.processesUnavailable(unavailable.reason.name),
                detail: unavailable.detail,
              )
            else if (result == null)
              PanelNotice.state(
                icon: Icons.hourglass_empty,
                text: l10n.processesWaiting,
              ),
            if (leftOut != null)
              PanelNotice.state(
                icon: Icons.filter_alt_outlined,
                text: switch (leftOut.total) {
                  final total? => l10n.processesShownOf(leftOut.shown, total),
                  null => l10n.processesShownSome(leftOut.shown),
                },
              ),
            if (flagCounts.isNotEmpty)
              PanelNotice.state(
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
        void open(ProcessRow row) => showProcess(
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
                filterFocus: _filterFocus,
                columns: columns,
                rows: rows,
                rowKey: (row) => row.pid,
                // The tree's rows come pre-ordered; a header still picks
                // the order of siblings, so it shows and flips that sort.
                sort: _sort,
                rowOrder: _tree ? TableRowOrder.asGiven : TableRowOrder.bySort,
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
          child: HeadedPanelBody(
            header: header,
            body: ListenableBuilder(
              listenable: clock,
              child: body,
              builder: (context, body) => Theme(
                data: _freshness(reading, sampling).stale ? greyed : theme,
                child: body!,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _filterField(AppLocalizations l10n) => TextField(
    controller: _filter,
    focusNode: _filterFocus,
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

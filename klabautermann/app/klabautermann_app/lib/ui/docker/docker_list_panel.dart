import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuEntry, ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../panel_kit.dart';
import '../sortable_table.dart';
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show searchTerms;
import 'docker_list_state.dart';

/// The shared scaffold of the Docker list sub-tabs (UIB-6, ARC-04): their
/// order, search, filter, watch, header notices, filter row, wide table
/// and narrow list, so the networks and volumes sub-tabs configure it
/// rather than repeat one another.
///
/// [S] is an engine summary type, [R] a row's entry type built from it,
/// [F] its filter enum and [C] its column enum, which the phone layout's
/// sort menu shows. The panel supplies its own columns, entries, labels,
/// notices and row widgets; the layout, state and focus order stay here,
/// identical in every panel.
class DockerListPanel<S, R, F extends Enum, C extends Enum>
    extends StatefulWidget {
  const DockerListPanel({
    super.key,
    required this.serverId,
    required this.visible,
    required this.list,
    required this.containers,
    required this.endpoint,
    required this.watch,
    required this.unwatch,
    required this.retry,
    required this.itemsOf,
    required this.failureOf,
    required this.initialSort,
    required this.filters,
    required this.initialFilter,
    required this.filterLabel,
    required this.shownFilter,
    required this.useKnown,
    required this.searchHint,
    required this.columns,
    required this.sortColumns,
    required this.sortLabel,
    required this.descendingFirst,
    required this.entries,
    required this.empty,
    required this.tableId,
    required this.rowKey,
    required this.heading,
    required this.phoneActions,
    required this.menuActions,
    required this.actionPoint,
    required this.failedText,
    required this.keptText,
    required this.readingText,
    required this.useUnknownText,
    this.actions,
    this.bodyClock,
  });

  final String serverId;
  final bool visible;

  /// The resource list, container list and endpoint listenables, read on
  /// every build: a server that left the fleet and came back has new
  /// ones (SYN-08).
  final ValueListenable<Object?> Function() list;
  final ValueListenable<DockerContainerList> Function() containers;
  final ValueListenable<DockerEndpointState?> Function() endpoint;

  /// Holds and lets go [serverId]'s watch while [visible].
  final void Function(String serverId) watch;
  final void Function(String serverId) unwatch;

  /// Retries the failed read behind the failure notice.
  final VoidCallback retry;

  /// The payload's summaries, or null until one was read, and why the
  /// latest read failed while they keep the last one.
  final List<S>? Function(Object? payload) itemsOf;
  final DockerQueryFailed? Function(Object? payload) failureOf;

  final TableSort initialSort;
  final List<F> filters;
  final F initialFilter;
  final String Function(AppLocalizations l10n, F filter) filterLabel;

  /// The filter the list applies: a panel may fall back to its all value
  /// while the use count is unknown.
  final F Function(F selected, bool useKnown) shownFilter;

  /// Whether a container list says which resources are unused.
  final bool Function(DockerContainerList containers) useKnown;

  final String Function(AppLocalizations l10n) searchHint;

  final List<SortableTableColumn<R>> Function(
    BuildContext context,
    AppLocalizations l10n,
  )
  columns;

  /// The phone layout's order choices, the direction each starts in, and
  /// their labels.
  final List<C> sortColumns;
  final String Function(AppLocalizations l10n, C column) sortLabel;
  final bool Function(C column) descendingFirst;

  /// [items] as the tab lists them after [filter] and [terms].
  final List<R> Function(
    List<S> items,
    List<ContainerSummary>? containers,
    F filter,
    List<String> terms,
  )
  entries;

  /// What an empty list says, which may name the filter or the search.
  final Widget Function(
    List<S> items,
    F filter,
    List<String> terms,
    AppLocalizations l10n,
  )
  empty;

  final String tableId;
  final Object Function(R entry) rowKey;

  /// A phone row's leading line: the name, tags or other first cell.
  final Widget Function(BuildContext context, R entry) heading;

  /// A phone row's trailing actions button.
  final Widget Function(BuildContext context, R entry) phoneActions;

  /// A wide row's verbs; no slot is drawn while [actionPoint] is not
  /// allowed at [serverId].
  final List<SidebarMenuEntry> Function(BuildContext context, R entry)
  menuActions;
  final ActionEntryPoint actionPoint;

  /// The header notices, named by the sub-tab.
  final String Function(AppLocalizations l10n, String failure) failedText;
  final String Function(AppLocalizations l10n) keptText;
  final String Function(AppLocalizations l10n) readingText;
  final String Function(AppLocalizations l10n) useUnknownText;

  /// The header's own button, between the notices and the filter row:
  /// a sub-tab's create or prune action, or null when it has none.
  final Widget? Function(BuildContext context)? actions;

  /// Wraps the body when only some figures age with the clock, as the
  /// volumes' ages do; null leaves the body unbuilt.
  final Listenable? Function(bool visible, List<S>? items)? bodyClock;

  @override
  State<DockerListPanel<S, R, F, C>> createState() =>
      _DockerListPanelState<S, R, F, C>();
}

class _DockerListPanelState<S, R, F extends Enum, C extends Enum>
    extends State<DockerListPanel<S, R, F, C>> {
  late final DockerListState _state = DockerListState(
    initialSort: widget.initialSort,
    watch: widget.watch,
    unwatch: widget.unwatch,
  );
  late F _filter = widget.initialFilter;

  @override
  void initState() {
    super.initState();
    _state.sync(visible: widget.visible, serverId: widget.serverId);
  }

  @override
  void didUpdateWidget(DockerListPanel<S, R, F, C> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _state.sync(visible: widget.visible, serverId: widget.serverId);
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.list(),
        widget.containers(),
        widget.endpoint(),
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final payload = widget.list().value;
    final containers = widget.containers().value;
    final endpoint = widget.endpoint().value;
    final items = widget.itemsOf(payload);
    final failure = widget.failureOf(payload);
    final useKnown = widget.useKnown(containers);
    // While no container list says which resources are unused, an empty
    // list never claims that none is.
    final useUnknown =
        containers.containers == null &&
        containers.failure != null &&
        (items?.isNotEmpty ?? false);

    return LayoutBuilder(
      builder: (context, box) {
        final wide = panelIsWide(context, box);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            // On the socket forward the events stream costs no session,
            // so low-session mode changes nothing the list shows.
            if ((endpoint?.lowSession ?? false) &&
                endpoint?.route?.rank != DockerRank.streamlocal)
              DockerNotice(
                icon: Icons.speed_outlined,
                text: l10n.dockerImagesLowSessionRelay,
              ),
            if (failure != null) ...[
              DockerNotice(
                icon: Icons.error_outline,
                text: widget.failedText(l10n, failure.failure.name),
                detail: failure.detail,
                action: TextButton(
                  onPressed: widget.retry,
                  child: Text(l10n.dockerRetry),
                ),
              ),
              if (items != null)
                DockerNotice(icon: Icons.history, text: widget.keptText(l10n)),
            ] else if (items == null)
              DockerNotice(
                icon: Icons.hourglass_empty,
                text: widget.readingText(l10n),
              ),
            if (useUnknown)
              DockerNotice(
                icon: Icons.error_outline,
                text: widget.useUnknownText(l10n),
                detail: containers.failure?.detail,
              ),
            if (items != null)
              if (widget.actions case final buildActions?)
                if (buildActions(context) case final actions?)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: actions,
                  ),
            if (items != null)
              DockerListFilterRow<F>(
                controller: _state.search,
                focusNode: _state.searchFocus,
                hint: widget.searchHint(l10n),
                clearTooltip: l10n.dockerImagesSearchClear,
                filters: widget.filters,
                label: widget.filterLabel,
                selected: widget.shownFilter(_filter, useKnown),
                enabled: useKnown,
                onChanged: () => setState(() {}),
                onSelected: (filter) => setState(() => _filter = filter),
              ),
            if (items != null && !wide) _sortControls(l10n),
          ],
        );
        final padding = EdgeInsets.all(wide ? 20 : 16);
        if (items == null) {
          return SingleChildScrollView(padding: padding, child: header);
        }

        final body = _body(
          context,
          items,
          containers.containers,
          useKnown: useKnown,
          wide: wide,
        );
        final clock = widget.bodyClock?.call(widget.visible, items);
        return Padding(
          padding: padding,
          child: HeadedPanelBody(
            header: header,
            body: clock == null
                ? body
                : ListenableBuilder(
                    listenable: clock,
                    builder: (context, _) => body,
                  ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    List<S> items,
    List<ContainerSummary>? containers, {
    required bool useKnown,
    required bool wide,
  }) {
    final l10n = AppLocalizations.of(context);
    final columns = widget.columns(context, l10n);
    final terms = searchTerms(_state.search.text);
    final filter = widget.shownFilter(_filter, useKnown);
    final entries = widget.entries(items, containers, filter, terms);
    final empty = widget.empty(items, filter, terms, l10n);
    if (!wide) {
      return _list(
        sortTableRows(entries, columns, _state.sort),
        columns,
        empty,
      );
    }

    return SortableTable<R>(
      tableId: widget.tableId,
      filterFocus: _state.searchFocus,
      columns: columns,
      rows: entries,
      rowKey: widget.rowKey,
      sort: _state.sort,
      onSort: (sort) => setState(() => _state.sort = sort),
      rowActions: actionsAllowedAt(context, widget.serverId, widget.actionPoint)
          ? (entry) => widget.menuActions(context, entry)
          : null,
      empty: empty,
    );
  }

  /// The phone layout's order: the table's columns in a menu, and the
  /// direction, which the button's tooltip names.
  Widget _sortControls(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final column = widget.sortColumns.byName(_state.sort.columnId);
    final ascending = _state.sort.direction == TableSortDirection.ascending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.dockerImagesSortBy,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        DropdownButton<C>(
          value: column,
          isDense: ghostIsDesktopPlatform(theme.platform),
          items: [
            for (final choice in widget.sortColumns)
              DropdownMenuItem(
                value: choice,
                child: Text(widget.sortLabel(l10n, choice)),
              ),
          ],
          onChanged: (choice) {
            if (choice == null) return;
            setState(
              () => _state.sort = TableSort(
                choice.name,
                widget.descendingFirst(choice)
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
            () => _state.sort = TableSort(
              _state.sort.columnId,
              ascending
                  ? TableSortDirection.descending
                  : TableSortDirection.ascending,
            ),
          ),
        ),
      ],
    );
  }

  /// The phone layout: two-line rows that wrap at large text, the name
  /// over the other figures, each row one node naming its cells as the
  /// table's rows do.
  Widget _list(
    List<R> entries,
    List<SortableTableColumn<R>> columns,
    Widget empty,
  ) {
    if (entries.isEmpty) return empty;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final cells = [
          for (final column in columns)
            (label: column.label, text: column.text(entry)),
        ];
        final row = Semantics(
          key: ValueKey('${widget.tableId}.row.${widget.rowKey(entry)}'),
          container: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                widget.heading(context, entry),
                Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    // The heading heads the row.
                    for (final cell in cells.skip(1))
                      Text(
                        l10n.dockerImagesFact(cell.label, cell.text),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        // The actions sit beside the row's one node, so a screen reader
        // reaches them as a button of their own.
        return Row(
          children: [
            Expanded(child: row),
            widget.phoneActions(context, entry),
          ],
        );
      },
    );
  }
}

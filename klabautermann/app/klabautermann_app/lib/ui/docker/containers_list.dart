import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../sortable_table.dart';
import 'container_badges.dart' show ContainerHealthBadge;
import 'container_selection.dart' show GroupHeading, Selectable;
import 'containers_view.dart';

/// A row's identity: a container's id, or a heading's project.
Object containerRowKey(ContainerListEntry entry) => switch (entry) {
  ContainerEntry(:final container) => container.id,
  ContainerGroupEntry(:final project) => 'group.${project ?? ''}',
};

/// The key tests find a phone row by, in the table rows' form.
String _phoneRowKey(ContainerListEntry entry) =>
    '${DockerWatchList.containers.name}.row.${containerRowKey(entry)}';

/// The phone list's built running rows, by id in build order, which
/// [onChanged] hears of as they come and go.
final class BuiltRows {
  BuiltRows(this.onChanged);

  final VoidCallback onChanged;
  final Map<String, int> _counts = {};

  List<String> get ids => _counts.keys.toList();

  void add(String id) {
    _counts.update(id, (count) => count + 1, ifAbsent: () => 1);
    onChanged();
  }

  void remove(String id) {
    final count = _counts[id];
    if (count == null) return;
    if (count > 1) {
      _counts[id] = count - 1;
    } else {
      _counts.remove(id);
    }
    onChanged();
  }
}

/// Counts [child] among [rows] while it is built.
class _BuiltRow extends StatefulWidget {
  const _BuiltRow({required this.id, required this.rows, required this.child});

  final String id;
  final BuiltRows rows;
  final Widget child;

  @override
  State<_BuiltRow> createState() => _BuiltRowState();
}

class _BuiltRowState extends State<_BuiltRow> {
  @override
  void initState() {
    super.initState();
    widget.rows.add(widget.id);
  }

  @override
  void didUpdateWidget(_BuiltRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id == widget.id) return;
    oldWidget.rows.remove(oldWidget.id);
    widget.rows.add(widget.id);
  }

  @override
  void dispose() {
    widget.rows.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The phone layout: headings that fold, and two-line rows that wrap at
/// large text, each one node naming its cells as the table's rows do.
/// The running rows the list has built, its viewport and the small
/// margin it builds ahead, count as on screen.
class ContainersList extends StatelessWidget {
  const ContainersList({
    super.key,
    required this.entries,
    required this.columns,
    required this.empty,
    required this.selecting,
    required this.shown,
    required this.selected,
    required this.builtRows,
    required this.projectSelection,
    required this.onToggleProject,
    required this.onToggle,
    required this.onOpen,
    required this.onToggleSelected,
    required this.onReportEmpty,
  });

  final List<ContainerListEntry> entries;
  final List<SortableTableColumn<ContainerListEntry>> columns;
  final Widget empty;
  final bool selecting;
  final List<ContainerSummary> shown;

  /// The selected containers' ids, which the rows check and name.
  final Set<String> selected;
  final BuiltRows builtRows;

  /// Whether every one of a project's containers among [shown] is
  /// selected (true), none is (false), or some are (null).
  final bool? Function(String? project, List<ContainerSummary> shown)
  projectSelection;

  final void Function(String? project, List<ContainerSummary> shown)
  onToggleProject;
  final void Function(String? project) onToggle;
  final void Function(ContainerSummary container) onOpen;
  final void Function(String id) onToggleSelected;

  /// Tells the panel that no running row is on screen, so it reports none.
  final VoidCallback onReportEmpty;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      onReportEmpty();
      return empty;
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry is ContainerGroupEntry) {
          final group = entry;
          final selected = selecting
              ? projectSelection(group.project, shown)
              : false;
          return Semantics(
            key: ValueKey(_phoneRowKey(group)),
            container: true,
            button: true,
            onTap: () => onToggle(group.project),
            customSemanticsActions: selecting
                ? {
                    CustomSemanticsAction(
                      label: selected ?? false
                          ? l10n.dockerContainersDeselectProject
                          : l10n.dockerContainersSelectProject,
                    ): () =>
                        onToggleProject(group.project, shown),
                  }
                : null,
            child: InkWell(
              excludeFromSemantics: true,
              onTap: () => onToggle(group.project),
              child: ConstrainedBox(
                // A touch needs a 48 dp target (A11Y-01).
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: GroupHeading(
                  group: group,
                  selection: selecting
                      ? (
                          selected: selected,
                          onToggle: () => onToggleProject(group.project, shown),
                        )
                      : null,
                ),
              ),
            ),
          );
        }

        final container = (entry as ContainerEntry).container;
        final checked = selected.contains(container.id);
        final cells = [
          for (final column in columns)
            if (column.text(entry) case final text when text.isNotEmpty)
              (id: column.id, label: column.label, text: text),
        ];
        final row = Semantics(
          key: ValueKey(_phoneRowKey(entry)),
          container: true,
          button: true,
          label: [
            for (final cell in cells)
              l10n.tableCellSemantics(cell.label, cell.text),
          ].join('\n'),
          checked: selecting ? checked : null,
          excludeSemantics: true,
          onTap: selecting
              ? () => onToggleSelected(container.id)
              : () => onOpen(container),
          child: InkWell(
            excludeFromSemantics: true,
            onTap: selecting
                ? () => onToggleSelected(container.id)
                : () => onOpen(container),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Selectable(
                checked: selecting ? checked : null,
                onChanged: () => onToggleSelected(container.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Flexible(
                          child: Text(
                            containerNameOf(container),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (container.health case final health?
                            when health != HealthStatus.none)
                          ContainerHealthBadge(health: health),
                      ],
                    ),
                    Wrap(
                      spacing: 16,
                      runSpacing: 2,
                      children: [
                        // The name and the health badge head the row.
                        for (final cell in cells.skip(1))
                          if (cell.id != ContainerColumn.health.name)
                            Text(
                              l10n.dockerContainersFact(cell.label, cell.text),
                              style: theme.textTheme.bodySmall,
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (!containerIsUp(container)) return row;
        return _BuiltRow(id: container.id, rows: builtRows, child: row);
      },
    );
  }
}

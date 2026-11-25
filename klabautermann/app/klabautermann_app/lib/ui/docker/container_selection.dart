import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import '../actions/action_preview.dart' show startAction;
import '../sortable_table.dart';
import 'containers_view.dart';
import 'docker_notice.dart';

/// The selection column's id in the table, beside [ContainerColumn]'s.
const _selectColumnId = 'select';

/// The bulk bar (CTR-07): how many are selected, a button per verb
/// naming how many of them it takes, and select-all and clear.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.containers,
    required this.shown,
    required this.selected,
    required this.serverId,
    required this.onSelectAll,
    required this.onClear,
  });

  final List<ContainerSummary> containers;
  final List<ContainerSummary> shown;

  /// The selected containers' ids, which the bar's verbs act on.
  final Set<String> selected;
  final String serverId;

  /// Adds every container [shown] to the selection.
  final ValueChanged<List<String>> onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selected = [
      for (final container in containers)
        if (this.selected.contains(container.id)) container,
    ];
    final tooMany = selected.length > kContainerBulkMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l10n.dockerContainersSelectedCount(selected.length)),
            for (final verb in ContainerBulkVerb.values)
              if (actionsAllowedAt(
                context,
                serverId,
                verb == ContainerBulkVerb.remove
                    ? ActionEntryPoint.containerRemove
                    : ActionEntryPoint.containerVerb,
              ))
                switch (bulkTargets(selected, verb)) {
                  final ids => OutlinedButton(
                    onPressed: ids.isEmpty || tooMany
                        ? null
                        : () => startAction(
                            context,
                            ContainerBulkAction(
                              serverId,
                              containerIds: ids,
                              verb: verb,
                            ),
                          ),
                    child: Text(
                      l10n.dockerContainersBulkVerb(verb.name, ids.length),
                    ),
                  ),
                },
            TextButton(
              onPressed: shown.every((c) => this.selected.contains(c.id))
                  ? null
                  : () => onSelectAll([for (final c in shown) c.id]),
              child: Text(l10n.dockerContainersSelectAll),
            ),
            TextButton(
              onPressed: selected.isEmpty ? null : onClear,
              child: Text(l10n.dockerContainersSelectNone),
            ),
          ],
        ),
        if (tooMany)
          DockerNotice(
            icon: Icons.info_outline,
            text: l10n.dockerContainersBulkMax(kContainerBulkMax),
          ),
      ],
    );
  }
}

/// The table's checkbox column while selecting; it reads as whether the
/// row is selected.
SortableTableColumn<ContainerListEntry> selectColumn(
  AppLocalizations l10n,
  Set<String> selected,
  ValueChanged<String> onToggle,
) => SortableTableColumn(
  id: _selectColumnId,
  label: l10n.dockerContainersColumnSelect,
  text: (entry) => switch (entry) {
    ContainerEntry(:final container) => l10n.dockerContainersRowSelected(
      selected.contains(container.id).toString(),
    ),
    ContainerGroupEntry() => '',
  },
  extent: const FixedColumnExtent(64),
  cell: (context, entry) => switch (entry) {
    ContainerEntry(:final container) => Checkbox(
      value: selected.contains(container.id),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onChanged: (_) => onToggle(container.id),
    ),
    ContainerGroupEntry() => const SizedBox.shrink(),
  },
);

/// [child] after a checkbox while selecting ([checked] not null), which
/// the row's own semantics name, so the box adds no node.
class Selectable extends StatelessWidget {
  const Selectable({
    super.key,
    required this.checked,
    required this.onChanged,
    required this.child,
  });

  final bool? checked;
  final VoidCallback onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final checked = this.checked;
    if (checked == null) return child;

    return Row(
      spacing: 8,
      children: [
        Checkbox(value: checked, onChanged: (_) => onChanged()),
        Expanded(child: child),
      ],
    );
  }
}

/// A compose project's heading: a chevron that says whether it is
/// folded, its name and its counts, read as one node with its state.
class GroupHeading extends StatelessWidget {
  const GroupHeading({super.key, required this.group, this.selection});

  final ContainerGroupEntry group;

  /// While selecting (CTR-07): whether its containers are all, none or
  /// some (null) selected, and what its checkbox does.
  final ({bool? selected, VoidCallback onToggle})? selection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = group.project ?? l10n.dockerContainersNoStack;
    final summary = l10n.dockerContainersGroupSummary(group.shown, group.up);
    final selection = this.selection;
    return Semantics(
      label: name,
      value: switch (selection?.selected) {
        _ when selection == null => summary,
        final selected => l10n.dockerContainersGroupSelection(
          summary,
          _GroupSelection.of(selected).name,
        ),
      },
      expanded: !group.collapsed,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          spacing: 4,
          children: [
            if (selection != null)
              Checkbox(
                tristate: true,
                value: selection.selected,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                // A tap on a partly selected heading selects them all.
                onChanged: (_) => selection.onToggle(),
              ),
            Icon(
              group.collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 16,
              color: muted,
            ),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How much of a heading's group is selected, as its words name it.
enum _GroupSelection {
  all,
  some,
  none;

  static _GroupSelection of(bool? selected) => switch (selected) {
    true => all,
    false => none,
    null => some,
  };
}

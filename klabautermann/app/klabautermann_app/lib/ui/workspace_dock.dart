import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/monitoring_controller.dart';
import '../controllers/workspace_dock.dart';
import '../l10n/app_localizations.dart';
import 'actions/cron_run_output.dart';
import 'actions/run_output_sheet.dart';
import 'docker/container_terminal.dart';
import 'docker/containers_view.dart' show containerNameOf;
import 'logs/logs_panel.dart';

export '../controllers/workspace_dock.dart';

/// The desktop workspace's dock (OV-10) for the routes under the desktop
/// shell; absent on phones and in tests that leave it out, where logs,
/// run output and shells open in sheets and pages instead.
class WorkspaceDockScope extends InheritedNotifier<WorkspaceDock> {
  const WorkspaceDockScope({
    super.key,
    required WorkspaceDock dock,
    required super.child,
  }) : super(notifier: dock);

  /// The dock for [context], without rebuilding it when the dock changes:
  /// callers only open items in it.
  static WorkspaceDock? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WorkspaceDockScope>()?.notifier;
}

/// The dock's height when it first expands, and the least and the most
/// share of the workspace it may take.
const double _defaultDockHeight = 280;
const double _minDockHeight = 120;
const double _maxDockShare = 0.7;

/// How far an arrow key moves the dock's edge.
const double _keyboardResizeStep = 24;

/// The workspace's dock toggle (OV-10), beside its tab strip: it opens
/// the server's logs in the dock when the dock holds nothing of it, and
/// otherwise expands or collapses it.
class WorkspaceDockButton extends StatelessWidget {
  const WorkspaceDockButton({
    super.key,
    required this.dock,
    required this.serverId,
  });

  final WorkspaceDock dock;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: dock,
      builder: (context, _) {
        final open = dock.expanded && dock.itemsFor(serverId).isNotEmpty;
        return IconButton(
          tooltip: open ? l10n.dockHide : l10n.dockShow,
          isSelected: open,
          icon: const Icon(Icons.call_to_action_outlined),
          selectedIcon: const Icon(Icons.call_to_action),
          onPressed: () {
            if (dock.itemsFor(serverId).isEmpty) {
              dock.show(DockedLogs(serverId));
              return;
            }
            dock.setExpanded(!open);
          },
        );
      },
    );
  }
}

/// The dock under the workspace's panels (OV-10): a tab per item of
/// [serverId], each with a way to close it, over the selected item's
/// content, which a dragged edge resizes. Every item stays built while
/// open, other servers' too, so a shell keeps running and a follow keeps
/// its lines while another server or a collapsed dock hides it.
class WorkspaceDockPane extends StatefulWidget {
  const WorkspaceDockPane({
    super.key,
    required this.dock,
    required this.monitoring,
    required this.serverId,
    required this.maxHeight,
  });

  final WorkspaceDock dock;
  final MonitoringController monitoring;
  final String serverId;

  /// The workspace's height below its tab strip, which bounds the dock.
  final double maxHeight;

  @override
  State<WorkspaceDockPane> createState() => _WorkspaceDockPaneState();
}

class _WorkspaceDockPaneState extends State<WorkspaceDockPane> {
  double _height = _defaultDockHeight;

  /// [height] within the dock's bounds; a workspace too short for the
  /// least height gives the dock its share instead, so nothing overflows.
  double _clamped(double height) {
    final most = widget.maxHeight * _maxDockShare;
    return height.clamp(math.min(_minDockHeight, most), most);
  }

  void _resizeBy(double delta) =>
      setState(() => _height = _clamped(_height + delta));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.dock,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final dock = widget.dock;
    final serverId = widget.serverId;
    final all = dock.items;
    final mine = dock.itemsFor(serverId);
    final selected = dock.selectedFor(serverId);
    final showing = dock.expanded && selected != null;
    final content = IndexedStack(
      index: selected == null ? null : all.indexOf(selected),
      sizing: StackFit.expand,
      children: [
        for (final item in all)
          KeyedSubtree(
            key: ValueKey(item),
            child: _DockContent(
              item: item,
              monitoring: widget.monitoring,
              visible: showing && item == selected,
            ),
          ),
      ],
    );
    final height = _clamped(_height);
    // The edge and tabs count toward the dock's share too: on a short
    // workspace the content gives way to them rather than overflowing.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight * _maxDockShare),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mine.isNotEmpty) ...[
            if (showing)
              _ResizeEdge(onResize: _resizeBy)
            else
              const Divider(height: 1),
            _DockTabs(
              dock: dock,
              serverId: serverId,
              items: mine,
              selected: selected,
            ),
          ],
          // Offstage keeps every item's state while this server's dock is
          // collapsed or holds nothing.
          Flexible(
            child: Offstage(
              offstage: !showing,
              child: SizedBox(height: showing ? height : 0, child: content),
            ),
          ),
        ],
      ),
    );
  }
}

/// The dock's top edge, dragged or moved with the arrow keys to resize it.
class _ResizeEdge extends StatelessWidget {
  const _ResizeEdge({required this.onResize});

  final ValueChanged<double> onResize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: l10n.dockResize,
      onIncrease: () => onResize(_keyboardResizeStep),
      onDecrease: () => onResize(-_keyboardResizeStep),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            onResize(_keyboardResizeStep);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            onResize(-_keyboardResizeStep);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) => MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) => onResize(-details.delta.dy),
              child: SizedBox(
                height: 8,
                child: Center(
                  child: Container(
                    height: Focus.of(context).hasFocus ? 3 : 1,
                    color: Focus.of(context).hasFocus
                        ? colors.primary
                        : colors.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tab per item of the server, with a way to close each, and the
/// collapse toggle.
class _DockTabs extends StatelessWidget {
  const _DockTabs({
    required this.dock,
    required this.serverId,
    required this.items,
    required this.selected,
  });

  final WorkspaceDock dock;
  final String serverId;
  final List<DockItem> items;
  final DockItem? selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 4,
                children: [
                  for (final item in items)
                    InputChip(
                      label: Text(dockItemTitle(l10n, item)),
                      selected: dock.expanded && item == selected,
                      showCheckmark: false,
                      onPressed: () => item == selected && dock.expanded
                          ? dock.setExpanded(false)
                          : dock.select(item),
                      deleteButtonTooltipMessage: l10n.dockClose(
                        dockItemTitle(l10n, item),
                      ),
                      onDeleted: () => dock.close(item),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: dock.expanded ? l10n.dockHide : l10n.dockShow,
            icon: Icon(dock.expanded ? Icons.expand_more : Icons.expand_less),
            onPressed: () => dock.setExpanded(!dock.expanded),
          ),
        ],
      ),
    );
  }
}

/// [item]'s name on its tab.
String dockItemTitle(AppLocalizations l10n, DockItem item) => switch (item) {
  DockedLogs() => l10n.dockLogs,
  DockedRunOutput(:final unit) => l10n.dockRunOutput(unit),
  DockedCommandRun(:final title) => l10n.dockRunOutput(title),
  DockedShell(:final container) => l10n.dockShell(containerNameOf(container)),
};

/// One item's content, built while it is open.
class _DockContent extends StatelessWidget {
  const _DockContent({
    required this.item,
    required this.monitoring,
    required this.visible,
  });

  final DockItem item;
  final MonitoringController monitoring;

  /// Whether the item shows: the Logs panel streams only then.
  final bool visible;

  @override
  Widget build(BuildContext context) => switch (item) {
    DockedLogs(:final serverId) => LogsPanel(
      monitoring: monitoring,
      serverId: serverId,
      visible: visible,
    ),
    DockedRunOutput(:final serverId, :final unit) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: RunOutputLog(
        monitoring: monitoring,
        serverId: serverId,
        unit: unit,
      ),
    ),
    DockedCommandRun(:final operations, :final planId, :final title) =>
      ListenableBuilder(
        listenable: operations,
        builder: (context, _) =>
            CronRunOutput(state: operations.runOf(planId), title: title),
      ),
    DockedShell(:final serverId, :final container) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ContainerShellPane(
        monitoring: monitoring,
        serverId: serverId,
        container: container,
      ),
    ),
  };
}

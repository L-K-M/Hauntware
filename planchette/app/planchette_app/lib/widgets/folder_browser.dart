import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/folder_workspace.dart';

/// The same file rows and order as Poltergeist, with opening as the primary
/// action. The host owns documents and remote checkouts.
class FolderBrowser extends StatefulWidget {
  const FolderBrowser({
    super.key,
    required this.workspace,
    required this.onOpen,
    this.enabled = true,
  });
  final FolderWorkspace workspace;
  final ValueChanged<RemoteFileEntry> onOpen;
  final bool enabled;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  final _focus = FocusNode(debugLabel: 'Workspace files');
  String? _selected;

  void _move(int direction) {
    final entries = widget.workspace.entries;
    if (entries.isEmpty) return;
    final current = entries.indexWhere((entry) => entry.path == _selected);
    final next = (current + direction).clamp(0, entries.length - 1);
    setState(() => _selected = entries[next].path);
  }

  void _open(RemoteFileEntry entry) {
    if (!widget.enabled || widget.workspace.loading) return;
    setState(() => _selected = entry.path);
    _focus.requestFocus();
    if (entry.type == RemoteFileType.directory) {
      unawaited(widget.workspace.navigate(entry.path));
      return;
    }
    if (entry.type == RemoteFileType.file ||
        entry.type == RemoteFileType.symbolicLink) {
      widget.onOpen(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final entries = workspace.entries;
    final enabled = widget.enabled && !workspace.loading;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('folder-browser'),
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(
                  workspace.isRemote
                      ? Icons.dns_outlined
                      : Icons.folder_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    workspace.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Close folder workspace',
                  onPressed: enabled
                      ? () => unawaited(workspace.close())
                      : null,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Tooltip(
            message: workspace.displayPath,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                workspace.displayPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Workspace root',
                onPressed: enabled
                    ? () => unawaited(workspace.navigate(workspace.root!))
                    : null,
                icon: const Icon(Icons.home_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Parent folder',
                onPressed: enabled && workspace.canGoUp
                    ? () => unawaited(workspace.up())
                    : null,
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                tooltip: 'Refresh folder',
                onPressed: enabled
                    ? () => unawaited(workspace.refresh())
                    : null,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                tooltip: workspace.showHidden
                    ? 'Hide hidden files'
                    : 'Show hidden files',
                isSelected: workspace.showHidden,
                onPressed: enabled ? workspace.toggleHidden : null,
                icon: const Icon(Icons.visibility_outlined, size: 18),
              ),
            ],
          ),
          if (workspace.status case final status?
              when status.state != ServerConnectionState.connected)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                status.detail ?? status.state.name,
                style: TextStyle(color: scheme.error),
              ),
            ),
          if (workspace.error case final error?)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                error,
                style: TextStyle(color: scheme.error),
              ),
            ),
          if (workspace.loading) const LinearProgressIndicator(),
          const Divider(height: 1),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _move(-1),
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  final entry = entries
                      .where((entry) => entry.path == _selected)
                      .firstOrNull;
                  if (entry != null) _open(entry);
                },
              },
              child: Focus(
                focusNode: _focus,
                child: entries.isEmpty && !workspace.loading
                    ? const Center(child: Text('This folder is empty'))
                    : ListView.builder(
                        itemExtent: scaledGhostFileRowExtent(context),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return GhostFileRow(
                            key: ValueKey(entry.path),
                            item: GhostFileItem(
                              name: entry.name,
                              type: switch (entry.type) {
                                RemoteFileType.file => GhostFileNodeType.file,
                                RemoteFileType.directory =>
                                  GhostFileNodeType.directory,
                                RemoteFileType.symbolicLink =>
                                  GhostFileNodeType.symbolicLink,
                                RemoteFileType.other => GhostFileNodeType.other,
                              },
                              size: entry.size,
                              modifiedAt: entry.modifiedAt,
                            ),
                            selected: _selected == entry.path,
                            touch: true,
                            onPointerDown: (_) {},
                            onPointerMove: (_) {},
                            onPointerUp: (_) {},
                            onTap: () => _open(entry),
                            onLongPress: () {},
                            onOpen: () => _open(entry),
                          );
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }
}

class WorkspaceSplitView extends StatefulWidget {
  const WorkspaceSplitView({
    super.key,
    required this.browser,
    required this.editor,
  });
  final Widget browser;
  final Widget editor;

  @override
  State<WorkspaceSplitView> createState() => _WorkspaceSplitViewState();
}

class _WorkspaceSplitViewState extends State<WorkspaceSplitView> {
  static const _minimumBrowserWidth = 160.0;
  static const _minimumEditorWidth = 240.0;
  static const _dividerWidth = 6.0;
  double _width = 300;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final maximum =
          constraints.maxWidth - _minimumEditorWidth - _dividerWidth;
      if (maximum < _minimumBrowserWidth) {
        return Column(
          children: [
            SizedBox(
              height: math.min(240, constraints.maxHeight * 0.4),
              child: widget.browser,
            ),
            const Divider(height: 1),
            Expanded(child: widget.editor),
          ],
        );
      }
      final width = _width.clamp(_minimumBrowserWidth, maximum);
      return Row(
        children: [
          SizedBox(width: width, child: widget.browser),
          Semantics(
            label: 'File browser width',
            onIncrease: () => setState(
              () => _width = (width + 20).clamp(_minimumBrowserWidth, maximum),
            ),
            onDecrease: () => setState(
              () => _width = (width - 20).clamp(_minimumBrowserWidth, maximum),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: const ValueKey('workspace-divider'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => setState(
                  () => _width = (_width + details.delta.dx).clamp(
                    _minimumBrowserWidth,
                    maximum,
                  ),
                ),
                child: const SizedBox(
                  width: _dividerWidth,
                  height: double.infinity,
                  child: VerticalDivider(width: _dividerWidth),
                ),
              ),
            ),
          ),
          Expanded(child: widget.editor),
        ],
      );
    },
  );
}

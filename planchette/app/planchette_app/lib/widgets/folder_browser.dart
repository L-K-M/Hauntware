import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/app_settings.dart' show AppSettings;
import '../services/folder_workspace.dart';

/// The suite's sidebar chord, one definition for everywhere it is bound or
/// spelled: ⌃⌘S on Apple platforms, Ctrl+Alt+S elsewhere. Off Apple
/// platforms the binding carries `leftAltOnly`, so AltGr (which Windows
/// reports as Ctrl + right Alt) never triggers it.
SingleActivator sidebarShortcut(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => const SingleActivator(
    LogicalKeyboardKey.keyS,
    control: true,
    meta: true,
  ),
  _ => const SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true),
};

/// The icon button that hides or shows the folder-workspace sidebar: in the
/// browser's header while it shows, at the tab strip's leading edge while
/// hidden. Named for what it would do, with the chord in its tooltip.
class WorkspaceSidebarToggle extends StatelessWidget {
  const WorkspaceSidebarToggle({
    super.key,
    required this.visible,
    required this.onToggle,
    this.visualDensity,
  });

  /// Whether the sidebar shows now; the tooltip names the other state.
  final bool visible;

  final VoidCallback onToggle;

  /// Compact where the host row is, as the tab strip's is.
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final label = '${visible ? 'Hide' : 'Show'} sidebar';
    final keys = formatShortcutActivator(sidebarShortcut(platform), platform);
    // view_sidebar draws its panel on the reading direction's end: the
    // browser sits at the start, so the glyph mirrors in LTR.
    final ltr = Directionality.of(context) == TextDirection.ltr;
    return IconButton(
      tooltip: keys == null ? label : '$label $keys',
      visualDensity: visualDensity,
      onPressed: onToggle,
      icon: Transform.flip(
        flipX: ltr,
        child: const Icon(Icons.view_sidebar_outlined, size: 18),
      ),
    );
  }
}

/// The same file rows and order as Poltergeist, with opening as the primary
/// action. The host owns documents and remote checkouts.
class FolderBrowser extends StatefulWidget {
  const FolderBrowser({
    super.key,
    required this.workspace,
    required this.onOpen,
    required this.onToggleSidebar,
    this.enabled = true,
  });
  final FolderWorkspace workspace;
  final ValueChanged<RemoteFileEntry> onOpen;

  /// Hides the sidebar without closing the workspace; the browser shows
  /// only while the sidebar is visible.
  final VoidCallback onToggleSidebar;
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
                WorkspaceSidebarToggle(
                  visible: true,
                  onToggle: widget.onToggleSidebar,
                ),
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

/// The folder browser beside the editor while a folder workspace is open.
/// The browser hides without closing the workspace ([browserShown]); its
/// width starts from [initialBrowserWidth] and is reported, once settled by
/// a finished drag or keyboard step, through [onBrowserWidthSettled] for
/// the host to persist.
class WorkspaceSplitView extends StatefulWidget {
  const WorkspaceSplitView({
    super.key,
    required this.browser,
    required this.editor,
    this.browserShown = true,
    this.initialBrowserWidth = AppSettings.defaultSidebarWidth,
    this.onBrowserWidthSettled,
  });
  final Widget browser;
  final Widget editor;

  /// Whether the browser shows. A hidden browser leaves its slot empty
  /// rather than a different tree, so the editor keeps its state.
  final bool browserShown;

  /// The width the browser starts from, as last persisted. The widget owns
  /// the live width once mounted; later changes do not reset it.
  final double initialBrowserWidth;

  /// The width worth persisting: the user's request as a finished drag or
  /// keyboard step left it, not the transient values between.
  final ValueChanged<double>? onBrowserWidthSettled;

  @override
  State<WorkspaceSplitView> createState() => _WorkspaceSplitViewState();
}

class _WorkspaceSplitViewState extends State<WorkspaceSplitView> {
  static const _minimumBrowserWidth = AppSettings.minimumSidebarWidth;
  static const _minimumEditorWidth = 240.0;

  /// The visible line between the panes; the wider drag handle floats over
  /// it, so the panes' edges meet the line.
  static const _seamWidth = 1.0;
  static const _handleWidth = 6.0;

  late double _width = widget.initialBrowserWidth;

  /// The width the last build rendered, and the bounds it was clamped to.
  /// A drag starts from what the user sees, not a stale request left by a
  /// narrower window.
  late double _renderedWidth = widget.initialBrowserWidth;
  late double _renderedMaximum = double.infinity;
  double? _dragFrom;
  double _dragDelta = 0;

  void _onStart() {
    _dragFrom = _renderedWidth;
    _dragDelta = 0;
  }

  void _onDelta(double dx) {
    final from = _dragFrom;
    if (from == null) return;
    _dragDelta += dx;
    setState(() {
      _width = (from + _dragDelta).clamp(
        _minimumBrowserWidth,
        _renderedMaximum,
      );
    });
  }

  void _onEnd() {
    if (_dragFrom == null) return;
    _dragFrom = null;
    widget.onBrowserWidthSettled?.call(_width);
  }

  void _onStep(double delta) {
    setState(() {
      _width = (_renderedWidth + delta).clamp(
        _minimumBrowserWidth,
        _renderedMaximum,
      );
    });
    widget.onBrowserWidthSettled?.call(_width);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final maximum = constraints.maxWidth - _minimumEditorWidth - _seamWidth;
      if (maximum < _minimumBrowserWidth) {
        return Column(
          children: [
            widget.browserShown
                ? SizedBox(
                    height: math.min(240, constraints.maxHeight * 0.4),
                    child: widget.browser,
                  )
                : const SizedBox.shrink(),
            widget.browserShown
                ? const Divider(height: 1)
                : const SizedBox.shrink(),
            Expanded(child: widget.editor),
          ],
        );
      }
      final width = _width.clamp(_minimumBrowserWidth, maximum);
      _renderedWidth = width;
      _renderedMaximum = maximum;
      final overhang = (_handleWidth - _seamWidth) / 2;
      return Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                widget.browserShown
                    ? SizedBox(width: width, child: widget.browser)
                    : const SizedBox.shrink(),
                widget.browserShown
                    ? SizedBox(
                        width: _seamWidth,
                        height: double.infinity,
                        child: ColoredBox(
                          color: Theme.of(context).dividerColor,
                        ),
                      )
                    : const SizedBox.shrink(),
                Expanded(child: widget.editor),
              ],
            ),
          ),
          if (widget.browserShown)
            PositionedDirectional(
              top: 0,
              bottom: 0,
              start: width - overhang,
              width: _handleWidth,
              child: GhostResizeHandle(
                key: const ValueKey('workspace-divider'),
                label: 'File browser width',
                width: width,
                minimumWidth: _minimumBrowserWidth,
                maximumWidth: maximum,
                edge: GhostPaneEdge.leading,
                widthAfterStep: (delta) =>
                    (width + delta).clamp(_minimumBrowserWidth, maximum),
                onStep: _onStep,
                onStart: _onStart,
                onDelta: _onDelta,
                onEnd: _onEnd,
                handleWidth: _handleWidth,
                valueText: (width) => '${width.round()} pixels',
              ),
            ),
        ],
      );
    },
  );
}

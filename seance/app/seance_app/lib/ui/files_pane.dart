import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/external_file_opener.dart';
import '../services/file_export_service.dart';
import '../services/managed_remote_file.dart';
import '../services/remote_files_controller.dart';
import '../services/xterm_engine.dart';
import 'built_in_text_editor.dart';
import 'file_kinds.dart';

class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          // The arrow leaves Files from any folder. Only the system back
          // walks up the tree first (see _RemoteBrowserState), and the
          // default arrow would ask the same PopScope, so pop outright.
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
          title: Text(
            'Files · ${state.activeSession?.displayLabel ?? 'Session'}',
          ),
        ),
        body: const SafeArea(
          top: false,
          child: FilesPane(popAfterTerminalStage: true),
        ),
      ),
    );
  }
}

class FilesPane extends StatelessWidget {
  final bool popAfterTerminalStage;

  const FilesPane({super.key, this.popAfterTerminalStage = false});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final session = state.activeSession;
        if (session == null) {
          return const _FilesUnavailable(
            icon: Icons.folder_off_outlined,
            message: 'Open a terminal session to browse its files.',
          );
        }
        // A local shell has no SFTP subsystem and needs none — this pane
        // exists to reach files that are not already on this device.
        if (session.isLocal) {
          return const _FilesUnavailable(
            icon: Icons.folder_off_outlined,
            message: 'This shell is already on this device — use the terminal, '
                'or open a server session to browse its files.',
          );
        }
        if (!session.isConnected || session.files == null) {
          if (session.retainedLocalCopies.isNotEmpty) {
            return _RecoveredLocalEdits(
              session: session,
              state: state,
              popAfterTerminalStage: popAfterTerminalStage,
            );
          }
          return const _FilesUnavailable(
            icon: Icons.link_off,
            message: 'Reconnect this session to browse remote files.',
          );
        }
        // "Session N" numbers the shell sessions — editor tabs between them
        // do not count.
        final terminals = state
            .tabsForServer(session.serverId)
            .whereType<TerminalSession>()
            .toList();
        final ordinal =
            terminals.indexWhere((item) => item.id == session.id) + 1;
        return _RemoteBrowser(
          key: ValueKey(session.id),
          controller: session.files!,
          identity: '${session.displayLabel} · Session $ordinal',
          session: session,
          popAfterTerminalStage: popAfterTerminalStage,
        );
      },
    );
  }
}

class _RemoteBrowser extends StatefulWidget {
  final RemoteFilesController controller;
  final String identity;
  final TerminalSession session;

  /// True on the pushed [FilesScreen]: staging a path or opening an editor
  /// tab pops the screen, and system back walks up the tree before it does.
  final bool popAfterTerminalStage;

  const _RemoteBrowser({
    super.key,
    required this.controller,
    required this.identity,
    required this.session,
    required this.popAfterTerminalStage,
  });

  @override
  State<_RemoteBrowser> createState() => _RemoteBrowserState();
}

class _RemoteBrowserState extends State<_RemoteBrowser> {
  bool _dragging = false;
  final ExternalFileOpener _fileOpener = const ExternalFileOpener();
  final TextEditingController _filter = TextEditingController();
  final Set<String> _promptedDirtyCopies = {};

  /// The desktop listing's keyboard cursor — the path the ring sits on.
  String? _cursorPath;

  /// The pane's double-click window (the pane state times it itself, as
  /// Poltergeist's `_RowGestures` does): a second primary press on the
  /// same row inside it opens the entry.
  DateTime _lastPrimaryDownAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastPrimaryDownPath;

  final FocusNode _listFocus = FocusNode();
  final ScrollController _listScroll = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    _filter.dispose();
    _listFocus.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        _queueDirtyEditPrompt(controller);
        final content = Stack(
          children: [
            Column(
              children: [
                _BrowserHeader(
                  identity: widget.identity,
                  controller: controller,
                  onUpload: _pickUploads,
                  onUploadFolder: _supportsDesktopDrop
                      ? _pickUploadFolder
                      : null,
                  onNewFile: _createFile,
                  onNewFolder: _createFolder,
                  onNewSymbolicLink: _createSymbolicLink,
                  onEnterPath: _enterPath,
                  onCopyPath: () => _copyRemotePath(controller.currentPath),
                  onOpenTerminalHere: _openTerminalHere,
                  filterController: _filter,
                  onDownloadSelected:
                      _supportsDesktopDrop &&
                          controller.selectedPaths.isNotEmpty
                      ? _downloadSelected
                      : null,
                ),
                if (controller.loading)
                  const LinearProgressIndicator(minHeight: 2),
                if (controller.error != null)
                  _ErrorBanner(
                    message: controller.error!,
                    onRetry: controller.refresh,
                  ),
                Expanded(child: _browserBody(controller)),
                if (controller.localCopies.isNotEmpty)
                  _LocalCopiesPanel(
                    copies: controller.localCopies.values.toList(),
                    onOpen: _openManagedCopy,
                    editorChoices: (copy) => _editorChoices(copy.remotePath),
                    onOpenWith: (copy, editorId) =>
                        _openManagedCopy(copy, editorId: editorId),
                    onUpload: _uploadLocalCopy,
                    onDiscard: _discardLocalCopy,
                  ),
                if (controller.transfers.isNotEmpty)
                  _TransfersPanel(controller: controller),
                _BrowserFooter(
                  key: const ValueKey('files.footer'),
                  controller: controller,
                ),
              ],
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 18,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.file_upload,
                              size: 36,
                              color: FamilyPalette.of(
                                context,
                              ).glyph(FamilyHue.cyan),
                            ),
                            const SizedBox(height: 8),
                            const Text('Upload to this directory'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        final browser = widget.popAfterTerminalStage
            ? _systemBackGoesUp(controller, content)
            : content;
        if (!_supportsDesktopDrop) return browser;
        return DropTarget(
          enable:
              TickerMode.valuesOf(context).enabled &&
              (ModalRoute.of(context)?.isCurrent ?? true),
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (details) {
            setState(() => _dragging = false);
            unawaited(_uploadDroppedFiles(details.files));
          },
          child: browser,
        );
      },
    );
  }

  /// On the pushed Files screen, system back climbs one folder at a time the
  /// way a file manager's does, and leaves the screen once it reaches the
  /// root. The app bar's arrow still leaves from anywhere (see [FilesScreen]).
  /// After a failed listing (a parent the user may not read, say) back
  /// leaves too, so it can never get stuck retrying the same folder.
  ///
  /// Android only: it is the one platform with a system back. On iOS (and
  /// macOS, whose page transition is Cupertino's too) back is the edge
  /// swipe, which Flutter disables outright on a route that vetoes its pop,
  /// so a swipe below the root would do nothing at all instead of leaving.
  Widget _systemBackGoesUp(RemoteFilesController controller, Widget child) {
    if (Theme.of(context).platform != TargetPlatform.android) return child;
    return PopScope(
      canPop: !controller.canGoUp || controller.error != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(controller.goUp());
      },
      child: child,
    );
  }

  Widget _browserBody(RemoteFilesController controller) {
    if (!controller.initialized && controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!controller.initialized) {
      return Center(
        child: FilledButton.icon(
          onPressed: controller.initialize,
          icon: const Icon(Icons.refresh),
          label: const Text('Try SFTP again'),
        ),
      );
    }
    if (controller.entries.isEmpty && !controller.loading) {
      return InkWell(
        onTap: _pickUploads,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.folder_open,
                  size: 40,
                  color: FamilyPalette.of(context).glyph(FamilyHue.blue),
                ),
                const SizedBox(height: 10),
                Text(
                  controller.filterQuery.isNotEmpty || !controller.showHidden
                      ? 'No matching files'
                      : 'This directory is empty',
                ),
                const SizedBox(height: 4),
                const Text('Tap to choose files, or drop files here.'),
              ],
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) =>
          ghostIsDesktopPlatform(Theme.of(context).platform)
          ? _desktopListing(context, constraints.maxWidth, controller)
          : _compactListing(controller),
    );
  }

  /// The desktop listing (D32 §6): the shared column header over dense
  /// [GhostFileRow]s — pointer-down selection with Ctrl/⌘-toggle and
  /// Shift-range, pane-owned double-click timing, the keyboard cursor,
  /// and the verbs' context menu on right-click, Menu, or Shift+F10.
  Widget _desktopListing(
    BuildContext context,
    double width,
    RemoteFilesController controller,
  ) {
    final metrics = GhostFileColumnMetrics.forWidth(
      width,
      MediaQuery.textScalerOf(context),
      modifiedWidth: GhostFileColumnMetrics.modifiedWidthIn(
        context,
        today: (time) => 'Today at $time',
        yesterday: (time) => 'Yesterday at $time',
      ),
    );
    return GhostFileColumnMetricsScope(
      metrics: metrics,
      child: Column(
        children: [
          GhostFileColumnHeader(
            listId: 'files',
            sortColumn: switch (controller.sortField) {
              RemoteSortField.name => GhostFileColumn.name,
              RemoteSortField.size => GhostFileColumn.size,
              RemoteSortField.modifiedAt => GhostFileColumn.modified,
              // A type sort still lives in the ⋮ menu; no column claims
              // its chevron.
              RemoteSortField.type => null,
            },
            sortDirection:
                controller.sortDirection == RemoteSortDirection.ascending
                ? GhostFileSortDirection.ascending
                : GhostFileSortDirection.descending,
            onSort: (column) {
              final field = switch (column) {
                GhostFileColumn.name => RemoteSortField.name,
                GhostFileColumn.size => RemoteSortField.size,
                GhostFileColumn.modified => RemoteSortField.modifiedAt,
              };
              controller.setSort(
                field,
                controller.sortField == field &&
                        controller.sortDirection ==
                            RemoteSortDirection.ascending
                    ? RemoteSortDirection.descending
                    : RemoteSortDirection.ascending,
              );
            },
          ),
          Expanded(
            child: Focus(
              focusNode: _listFocus,
              onKeyEvent: _onListingKey,
              child: Listener(
                // A press anywhere in the listing arms the keyboard
                // focus; the rows' own Listeners see the same event.
                onPointerDown: (_) => _listFocus.requestFocus(),
                child: ListView.builder(
                  key: _listViewportKey,
                  controller: _listScroll,
                  itemExtent: scaledGhostFileRowExtent(context),
                  itemCount: controller.entries.length,
                  itemBuilder: (context, index) =>
                      _desktopRow(controller.entries[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The touch listing (D32 §9): the shared 56 dp rows — tap opens (or
  /// toggles while selecting), long-press extends the selection, ⋮ opens
  /// the verb menu.
  Widget _compactListing(RemoteFilesController controller) {
    return ListView.builder(
      itemExtent: scaledGhostCompactFileRowExtent(context),
      itemCount: controller.entries.length,
      itemBuilder: (context, index) {
        final entry = controller.entries[index];
        final localCopy = controller.localCopies[entry.path];
        final selecting = controller.selectedPaths.isNotEmpty;
        final selected = controller.selectedPaths.contains(entry.path);
        return Builder(
          builder: (itemContext) => GhostFileCompactRow(
            item: ghostFileItemOf(entry),
            selected: selected,
            selecting: selecting,
            onTap: () => selecting
                ? controller.toggleSelection(entry.path)
                : _openEntry(entry),
            onLongPress: () => controller.toggleSelection(entry.path),
            onActions: () {
              final box = itemContext.findRenderObject() as RenderBox?;
              unawaited(
                _showEntryMenu(
                  entry,
                  box == null
                      ? const Offset(32, 32)
                      : box.localToGlobal(box.size.centerRight(Offset.zero)),
                ),
              );
            },
            onRename: ghostFileNameIsFlagged(entry.name)
                ? null
                : () => _rename(entry),
            trailing: localCopy == null
                ? null
                : IconButton(
                    tooltip: 'Upload local changes',
                    iconSize: 20,
                    onPressed: () => unawaited(_uploadLocalCopy(localCopy)),
                    icon: const Icon(Icons.edit_note),
                  ),
          ),
        );
      },
    );
  }

  GhostFileRow _desktopRow(RemoteFileEntry entry) {
    final controller = widget.controller;
    final selected = controller.selectedPaths.contains(entry.path);
    final cursor = _cursorPath == entry.path;
    final localCopy = controller.localCopies[entry.path];
    return GhostFileRow(
      item: ghostFileItemOf(entry),
      // The disclosure column stays reserved so names line up with the
      // header's Name label; this listing never expands in place, so no
      // row draws a triangle.
      outline: true,
      selected: selected,
      active: true,
      cursorRing: cursor,
      onPointerDown: (event) => _rowPointerDown(entry, event),
      onPointerMove: (_) {},
      onPointerUp: (_) {},
      onTap: () {},
      onLongPress: () {},
      onOpen: () => _openEntry(entry),
      onRename: ghostFileNameIsFlagged(entry.name)
          ? null
          : () => _rename(entry),
      trailing: _rowTrailing(entry, localCopy),
    );
  }

  Widget _rowTrailing(RemoteFileEntry entry, ManagedRemoteFile? localCopy) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (localCopy != null)
            _DenseActionIcon(
              tooltip: 'Upload local changes',
              icon: Icons.edit_note,
              onPressedAt: (_) => unawaited(_uploadLocalCopy(localCopy)),
            ),
          _DenseActionIcon(
            tooltip: 'Actions',
            icon: Icons.more_vert,
            onPressedAt: (rect) =>
                unawaited(_showEntryMenu(entry, rect.center)),
          ),
        ],
      );

  /// A desktop row's primary/secondary press. Selection lands on
  /// pointer-down; the double-click window stays here, in pane state.
  void _rowPointerDown(RemoteFileEntry entry, PointerDownEvent event) {
    final controller = widget.controller;
    _setCursor(entry.path);
    if (event.buttons & kSecondaryMouseButton != 0) {
      // A right-click on an unselected row selects it first, like the
      // file managers: the menu then names what it acts on.
      if (!controller.selectedPaths.contains(entry.path)) {
        controller.selectOnly(entry.path);
      }
      unawaited(_showEntryMenu(entry, event.position));
      return;
    }
    if (event.buttons & kPrimaryMouseButton == 0) return;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final isApple = Theme.of(context).platform == TargetPlatform.macOS;
    final toggle = isApple
        ? pressed.contains(LogicalKeyboardKey.metaLeft) ||
              pressed.contains(LogicalKeyboardKey.metaRight)
        : pressed.contains(LogicalKeyboardKey.controlLeft) ||
              pressed.contains(LogicalKeyboardKey.controlRight);
    final shift =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    if (shift) {
      controller.selectRangeTo(entry.path);
      return;
    }
    if (toggle) {
      controller.toggleSelection(entry.path);
      return;
    }
    final now = DateTime.now();
    final doubleClick =
        _lastPrimaryDownPath == entry.path &&
        now.difference(_lastPrimaryDownAt) <= kDoubleTapTimeout;
    _lastPrimaryDownAt = now;
    _lastPrimaryDownPath = entry.path;
    controller.selectOnly(entry.path);
    if (doubleClick) {
      _lastPrimaryDownPath = null;
      _openEntry(entry);
    }
  }

  void _openEntry(RemoteFileEntry entry) {
    if (entry.isDirectory) {
      unawaited(widget.controller.navigate(entry.path));
    } else {
      unawaited(_openRemoteFile(entry));
    }
  }

  void _setCursor(String path) {
    if (_cursorPath == path) return;
    setState(() => _cursorPath = path);
  }

  /// The listing's keyboard contract: arrows move the cursor (Shift
  /// extends the range, a plain move single-selects), Enter opens,
  /// Space toggles, Ctrl/⌘+A selects all, Escape clears, and the Menu
  /// key or Shift+F10 opens the cursor row's verbs.
  KeyEventResult _onListingKey(FocusNode node, KeyEvent event) {
    // Key-down and the arrows' key-repeat run; a held Enter would keep
    // re-opening rows and repeating Space/select-all is meaningless, so
    // only cursor movement honours auto-repeat.
    if (event is! KeyDownEvent &&
        !(event is KeyRepeatEvent &&
            (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                event.logicalKey == LogicalKeyboardKey.arrowUp))) {
      return KeyEventResult.ignored;
    }
    final controller = widget.controller;
    final entries = controller.entries;
    if (entries.isEmpty) return KeyEventResult.ignored;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final isApple = Theme.of(context).platform == TargetPlatform.macOS;
    final modifier = isApple
        ? pressed.contains(LogicalKeyboardKey.metaLeft) ||
              pressed.contains(LogicalKeyboardKey.metaRight)
        : pressed.contains(LogicalKeyboardKey.controlLeft) ||
              pressed.contains(LogicalKeyboardKey.controlRight);
    final shift =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyA && modifier) {
      controller.selectAll();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      controller.clearSelection();
      return KeyEventResult.handled;
    }
    var index = entries.indexWhere((entry) => entry.path == _cursorPath);
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      index = index < 0
          ? (delta > 0 ? 0 : entries.length - 1)
          : (index + delta).clamp(0, entries.length - 1);
      final target = entries[index];
      _setCursor(target.path);
      shift
          ? controller.selectRangeTo(target.path)
          : controller.selectOnly(target.path);
      _scrollCursorIntoView(index);
      return KeyEventResult.handled;
    }
    if (index < 0) return KeyEventResult.ignored;
    final entry = entries[index];
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _openEntry(entry);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      controller.toggleSelection(entry.path);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && shift)) {
      unawaited(_showEntryMenu(entry, _cursorMenuPosition(index)));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Keeps the cursor row inside the viewport on keyboard moves — the
  /// rows are fixed-extent, so the target scroll offset is exact.
  void _scrollCursorIntoView(int index) {
    if (!_listScroll.hasClients) return;
    final extent = scaledGhostFileRowExtent(context);
    final position = _listScroll.position;
    final top = index * extent;
    final bottom = top + extent;
    if (top < position.pixels) {
      _listScroll.jumpTo(top);
    } else if (bottom > position.pixels + position.viewportDimension) {
      _listScroll.jumpTo(bottom - position.viewportDimension);
    }
  }

  /// Where the cursor row's menu anchors for the Menu key/Shift+F10 —
  /// the row's own rect inside the viewport, not the screen edge.
  Offset _cursorMenuPosition(int index) {
    final box =
        _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const Offset(32, 32);
    final origin = box.localToGlobal(Offset.zero);
    final extent = scaledGhostFileRowExtent(context);
    final offset = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final center = (index * extent) - offset + extent / 2;
    return Offset(
      origin.dx + box.size.width * 0.4,
      (origin.dy + center).clamp(origin.dy, origin.dy + box.size.height),
    );
  }

  /// The row's verb menu — the ⋮, a right-click, or the keyboard — all
  /// in the shared ghost skin.
  Future<void> _showEntryMenu(
    RemoteFileEntry entry,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _entryMenuItems(entry),
    );
    if (value == null || !mounted) return;
    _dispatchEntryVerb(entry, value);
  }

  List<PopupMenuEntry<String>> _entryMenuItems(RemoteFileEntry entry) {
    final palette = FamilyPalette.of(context);
    final localCopy = widget.controller.localCopies[entry.path];
    final editors = entry.type == RemoteFileType.file
        ? _editorChoices(entry.path)
        : const <_EditorChoice>[];
    final selected = widget.controller.selectedPaths.contains(entry.path);
    return [
      GhostMenuItem(
        context: context,
        value: 'open',
        icon: entry.isDirectory ? Icons.folder_open : Icons.open_in_new,
        iconColor: palette.glyph(FamilyHue.blue),
        label: entry.isDirectory ? 'Open' : 'Open locally',
      ),
      GhostMenuItem(
        context: context,
        value: 'select',
        icon: selected ? Icons.check_box : Icons.check_box_outline_blank,
        iconColor: palette.glyph(FamilyHue.graphite),
        label: selected ? 'Deselect' : 'Select',
      ),
      for (final editor in editors)
        GhostMenuItem(
          context: context,
          value: 'open_with:${editor.id}',
          icon: Icons.edit_outlined,
          iconColor: palette.glyph(FamilyHue.graphite),
          label: 'Open with ${editor.label}',
        ),
      if (localCopy != null)
        GhostMenuItem(
          context: context,
          value: 'upload',
          icon: Icons.edit_note,
          iconColor: palette.glyph(FamilyHue.cyan),
          label: 'Upload local changes',
        ),
      if (entry.type == RemoteFileType.file ||
          (entry.isDirectory && _supportsDesktopDrop))
        GhostMenuItem(
          context: context,
          value: 'download',
          icon: Icons.download,
          iconColor: palette.glyph(FamilyHue.cyan),
          label: 'Download / Save as…',
        ),
      if (entry.type == RemoteFileType.file && _supportsSharing)
        GhostMenuItem(
          context: context,
          value: 'share',
          icon: Icons.share,
          iconColor: palette.glyph(FamilyHue.cyan),
          label: 'Share…',
        ),
      const GhostMenuDivider(),
      GhostMenuItem(
        context: context,
        value: 'copy_path',
        icon: Icons.link,
        iconColor: palette.glyph(FamilyHue.graphite),
        label: 'Copy remote path',
      ),
      if (entry.isDirectory)
        GhostMenuItem(
          context: context,
          value: 'terminal_here',
          icon: Icons.terminal,
          iconColor: palette.glyph(FamilyHue.graphite),
          label: 'Open terminal here',
        ),
      GhostMenuItem(
        context: context,
        value: 'rename',
        icon: Icons.edit,
        iconColor: palette.glyph(FamilyHue.graphite),
        // A flagged (undecodable) name cannot build a valid wire path —
        // rename stays visible but inert, matching the row's semantics.
        enabled: !ghostFileNameIsFlagged(entry.name),
        label: 'Rename…',
      ),
      GhostMenuItem(
        context: context,
        value: 'properties',
        icon: Icons.info_outline,
        iconColor: palette.glyph(FamilyHue.graphite),
        label: 'Properties…',
      ),
      const GhostMenuDivider(),
      GhostMenuItem(
        context: context,
        value: 'delete',
        icon: Icons.delete_outline,
        iconColor: palette.glyph(FamilyHue.red),
        label: 'Delete…',
      ),
    ];
  }

  void _dispatchEntryVerb(RemoteFileEntry entry, String value) {
    if (value.startsWith('open_with:')) {
      unawaited(
        _openRemoteFileWithEditor(entry, value.substring('open_with:'.length)),
      );
      return;
    }
    switch (value) {
      case 'open':
        _openEntry(entry);
      case 'select':
        widget.controller.toggleSelection(entry.path);
      case 'upload':
        final copy = widget.controller.localCopies[entry.path];
        if (copy != null) unawaited(_uploadLocalCopy(copy));
      case 'download':
        if (entry.type == RemoteFileType.file) {
          unawaited(_exportRemoteFile(entry));
        } else {
          unawaited(_downloadRemoteEntries([entry]));
        }
      case 'share':
        unawaited(_shareRemoteFile(entry));
      case 'copy_path':
        unawaited(_copyRemotePath(entry.path));
      case 'terminal_here':
        unawaited(_openTerminalHere(entry.path));
      case 'rename':
        unawaited(_rename(entry));
      case 'properties':
        unawaited(_showProperties(entry));
      case 'delete':
        unawaited(_delete(entry));
    }
  }

  Future<void> _pickUploads() async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withReadStream: true,
      );
      if (result == null) return;
      final targetDirectory = widget.controller.currentPath;
      if (targetDirectory == null) return;
      final existingNames = {
        for (final entry in widget.controller.entries) entry.name,
      };
      for (final file in result.files) {
        final stream = file.readStream;
        final path = file.path;
        if (stream == null && path == null) {
          _showError('The selected document could not be read.');
          continue;
        }
        await _uploadSource(
          name: file.name,
          length: file.size,
          openRead: () => stream ?? File(path!).openRead(),
          targetDirectory: targetDirectory,
          destinationExists: existingNames.contains(file.name),
        );
        existingNames.add(file.name);
      }
    } catch (e) {
      _showError(e);
    } finally {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await FilePicker.clearTemporaryFiles();
        } catch (_) {
          // Some platform implementations do not keep picker-owned temp files.
        }
      }
    }
  }

  Future<void> _pickUploadFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder to upload',
      );
      if (path == null) return;
      if (!mounted) return;
      final replace = await _confirm(
        title: 'Upload folder?',
        message:
            'The folder is merged with the remote destination. Existing files '
            'are replaced only if you continue.',
        confirmLabel: 'Upload and Replace',
      );
      if (!replace) return;
      await widget.controller.uploadDirectory(
        Directory(path),
        overwriteExisting: true,
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _uploadDroppedFiles(Iterable<DropItem> files) async {
    final targetDirectory = widget.controller.currentPath;
    if (targetDirectory == null) return;
    final existingNames = {
      for (final entry in widget.controller.entries) entry.name,
    };
    for (final file in files) {
      final bookmark = file.extraAppleBookmark;
      var scopedAccess = false;
      try {
        if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
          scopedAccess = await DesktopDrop.instance
              .startAccessingSecurityScopedResource(bookmark: bookmark);
        }
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (file is DropItemDirectory ||
            type == FileSystemEntityType.directory) {
          final replace = await _confirm(
            title: 'Upload ${file.name}?',
            message:
                'The folder is merged recursively. Existing files are replaced.',
            confirmLabel: 'Upload and Replace',
          );
          if (replace) {
            await widget.controller.uploadDirectory(
              Directory(file.path),
              directory: targetDirectory,
              overwriteExisting: true,
            );
          }
        } else {
          await _uploadXFile(
            file,
            targetDirectory: targetDirectory,
            destinationExists: existingNames.contains(file.name),
          );
        }
        existingNames.add(file.name);
      } finally {
        if (scopedAccess && bookmark != null) {
          await DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        }
      }
    }
  }

  Future<void> _uploadXFile(
    XFile file, {
    required String targetDirectory,
    required bool destinationExists,
  }) async {
    try {
      await _uploadSource(
        name: file.name,
        length: await file.length(),
        openRead: file.openRead,
        targetDirectory: targetDirectory,
        destinationExists: destinationExists,
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _uploadSource({
    required String name,
    required int length,
    required Stream<List<int>> Function() openRead,
    required String targetDirectory,
    required bool destinationExists,
  }) async {
    var overwrite = false;
    if (destinationExists) {
      if (!mounted) return;
      overwrite = await _confirm(
        title: 'Replace $name?',
        message: 'An item with this name already exists on the server.',
        confirmLabel: 'Replace',
      );
      if (!overwrite) return;
    }
    await widget.controller.upload(
      name: name,
      content: openRead(),
      length: length,
      overwrite: overwrite,
      directory: targetDirectory,
    );
  }

  Future<void> _openRemoteFile(RemoteFileEntry entry) async {
    if (entry.isSymbolicLink) {
      _showError('Opening symbolic links locally is not supported yet.');
      return;
    }
    final registry = AppScope.of(context).services.settings.editorRegistry;
    if (_refusesLaunch(entry, registry.effectiveDefaultFor(entry.path))) {
      return;
    }
    final maximumBytes = registry.checkoutMaximumBytes(entry.path);
    if (maximumBytes != null &&
        entry.size != null &&
        entry.size! > maximumBytes) {
      _showError('The built-in editor supports text files up to 4 MB.');
      return;
    }
    try {
      final copy = await widget.controller.checkoutRemoteFile(
        entry,
        maximumBytes: maximumBytes,
      );
      if (!mounted) return;
      await _openLocalCopy(copy);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openRemoteFileWithEditor(
    RemoteFileEntry entry,
    String editorId,
  ) async {
    if (_refusesLaunch(entry, editorId)) return;
    if (editorId == EditorRegistry.builtInId &&
        entry.size != null &&
        entry.size! > builtInEditorMaximumBytes) {
      _showError('The built-in editor supports text files up to 4 MB.');
      return;
    }
    try {
      final copy = await widget.controller.checkoutRemoteFile(
        entry,
        maximumBytes: editorId == EditorRegistry.builtInId
            ? builtInEditorMaximumBytes
            : null,
      );
      if (!mounted) return;
      await _openLocalCopy(copy, editorId: editorId);
    } catch (error) {
      _showError(error);
    }
  }

  /// Refuses [entry] by its listed name before anything downloads when
  /// [editorId] is the system's default app and that app would run it.
  /// The opener checks the checkout's name again at launch.
  bool _refusesLaunch(RemoteFileEntry entry, String editorId) {
    if (editorId != EditorRegistry.systemDefaultId) return false;
    if (!_fileOpener.launchWouldExecute(entry.name)) return false;

    _showError(ExecutableLaunchRefused(entry.name));
    return true;
  }

  /// Opens a managed copy — routed through [RemoteFilesController]'s checkout
  /// so a stale copy is refreshed from the server before the editor sees it.
  Future<void> _openManagedCopy(
    ManagedRemoteFile copy, {
    String? editorId,
  }) async {
    final registry = AppScope.of(context).services.settings.editorRegistry;
    try {
      final fresh = await widget.controller.checkoutRemoteFile(
        copy.remoteSnapshot,
        maximumBytes: registry.checkoutMaximumBytes(
          copy.remotePath,
          editorId: editorId,
        ),
      );
      if (!mounted) return;
      await _openLocalCopy(fresh, editorId: editorId);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openLocalCopy(
    ManagedRemoteFile copy, {
    String? editorId,
  }) async {
    try {
      final state = AppScope.of(context);
      final registry = state.services.settings.editorRegistry;
      final file = widget.controller.localFile(copy);
      final selected =
          editorId ??
          await registry.effectiveDefaultForCheckout(copy.remotePath, file);
      if (selected == EditorRegistry.builtInId) {
        // The built-in editor is a tab beside the terminals, not a route —
        // the shell and the file stay one tap apart.
        state.openEditorTab(copy);
        // On the pushed Files route (the narrow layout) the new tab is
        // underneath this screen, so get out of its way.
        if (widget.popAfterTerminalStage && mounted) {
          Navigator.of(context).pop();
        }
        return;
      }
      if (selected == EditorRegistry.systemDefaultId) {
        await _fileOpener.openSystemDefault(file.path);
      } else {
        final editor = registry.byId(selected);
        if (editor == null) {
          throw StateError('The selected editor no longer exists.');
        }
        await _fileOpener.openWith(file.path, editor);
      }
    } catch (e) {
      _showError(e);
    }
  }

  List<_EditorChoice> _editorChoices(String path) {
    final registry = AppScope.of(context).services.settings.editorRegistry;
    return [
      const _EditorChoice(EditorRegistry.builtInId, 'Built-in text editor'),
      if (currentEditorHostPlatform != null)
        const _EditorChoice(EditorRegistry.systemDefaultId, 'System default'),
      for (final editor in registry.compatibleEditors(path))
        _EditorChoice(editor.id, editor.displayName),
    ];
  }

  Future<bool> _uploadLocalCopy(
    ManagedRemoteFile copy, {
    bool notifySuccess = true,
  }) => uploadManagedLocalCopy(
    context,
    widget.controller,
    copy,
    notifySuccess: notifySuccess,
  );

  Future<void> _discardLocalCopy(ManagedRemoteFile copy) async {
    final discard = await _confirm(
      title: 'Discard local copy?',
      message: 'Any changes made in the local editor will be deleted.',
      confirmLabel: 'Discard',
    );
    if (discard) await widget.controller.removeLocalCopy(copy.remotePath);
  }

  void _queueDirtyEditPrompt(RemoteFilesController controller) {
    final dirtyIds = {
      for (final copy in controller.localCopies.values)
        if (copy.dirty) copy.id,
    };
    _promptedDirtyCopies.removeWhere((id) => !dirtyIds.contains(id));
    final dirty = controller.localCopies.values.where(
      (copy) =>
          copy.dirty &&
          !_promptedDirtyCopies.contains(copy.id) &&
          !controller.isUploadingLocalCopy(copy.remotePath),
    );
    if (dirty.isEmpty) return;
    final copy = dirty.first;
    _promptedDirtyCopies.add(copy.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Re-check right before showing: a save-and-upload from the built-in
      // editor may already have uploaded (or be uploading) this copy, and a
      // stale "Upload it?" prompt would read as a confirmation request.
      final current = controller.localCopies[copy.remotePath];
      if (current == null ||
          !current.dirty ||
          controller.isUploadingLocalCopy(current.remotePath)) {
        _promptedDirtyCopies.remove(copy.id);
        return;
      }
      showTopToastIn(
        context,
        message:
            '${remoteBasename(copy.remotePath)} changed locally. Upload it?',
        duration: const Duration(seconds: 12),
        actionLabel: 'Upload',
        onAction: () => unawaited(_uploadLocalCopy(copy)),
      );
    });
  }

  Future<void> _copyRemotePath(String? path) async {
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    _showMessage('Copied remote path');
  }

  Future<void> _openTerminalHere([String? path]) async {
    final target = path ?? widget.controller.currentPath;
    if (target == null) return;
    if (!widget.session.isConnected) {
      _showError('Reconnect this session first.');
      return;
    }
    final engine = widget.session.engine;
    final integration = engine.shellIntegration.value;
    final shell = integration.shell;
    if (shell == null) {
      _showError('Shell integration is required. Copy the path instead.');
      return;
    }
    if (integration.phase != TerminalPromptPhase.acceptingInput) {
      _showError('Wait for the shell prompt.');
      return;
    }
    if (integration.inputSincePrompt || engine.pendingInput.isNotEmpty) {
      _showError('Clear or submit the current terminal input first.');
      return;
    }
    late final String preview;
    try {
      preview = buildChangeDirectoryCommand(target, shell: shell);
    } on ArgumentError {
      _showError('This path cannot be staged safely.');
      return;
    }
    final insert = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Insert command into terminal?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Review the command. Séance will not press Enter.'),
            const SizedBox(height: 12),
            SelectableText(preview),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Insert'),
          ),
        ],
      ),
    );
    if (insert != true || !mounted) return;
    final result = engine.stageChangeDirectory(target);
    final message = switch (result) {
      TerminalStageResult.staged =>
        'Inserted into the prompt. Press Enter in the terminal to run.',
      TerminalStageResult.shellIntegrationRequired =>
        'Shell integration is required. Copy the path instead.',
      TerminalStageResult.promptNotReady => 'Wait for the shell prompt.',
      TerminalStageResult.pendingInput =>
        'Clear or submit the current terminal input first.',
      TerminalStageResult.invalidPath => 'This path cannot be staged safely.',
    };
    if (result != TerminalStageResult.staged) {
      _showError(message);
      return;
    }
    _showMessage(message);
    if (widget.popAfterTerminalStage && mounted) Navigator.of(context).pop();
  }

  Future<StagedExportFile> _stageRemoteFile(RemoteFileEntry entry) async {
    if (entry.type != RemoteFileType.file) {
      throw StateError('Only regular files can be downloaded.');
    }
    final root = await getTemporaryDirectory();
    final directory = await root.createTemp('seance-export-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeLocalName(entry.name)}',
    );
    IOSink? sink;
    try {
      sink = file.openWrite();
      await widget.controller.download(entry, sink);
      await sink.flush();
      await sink.close();
      return StagedExportFile(
        file: file,
        fileName: _safeLocalName(entry.name),
        mimeType: _mimeType(entry.name),
      );
    } catch (_) {
      await sink?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _exportRemoteFile(RemoteFileEntry entry) async {
    StagedExportFile? staged;
    try {
      staged = await _stageRemoteFile(entry);
      final service = FileExportService(
        desktopSave: (file) async {
          final destination = await FilePicker.saveFile(
            fileName: file.fileName,
          );
          if (destination == null) return null;
          await _copyExportAtomically(file.file, File(destination));
          return destination;
        },
      );
      if (Platform.isAndroid && !await service.hasExportDirectoryAccess()) {
        if (!await service.pickExportDirectory()) return;
      }
      final destination = await service.exportFile(staged);
      if (destination != null) _showMessage('Saved ${staged.fileName}');
    } catch (error) {
      _showError(error);
    } finally {
      await _deleteStagedExport(staged);
    }
  }

  Future<void> _shareRemoteFile(RemoteFileEntry entry) async {
    StagedExportFile? staged;
    try {
      staged = await _stageRemoteFile(entry);
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      final origin = renderBox == null
          ? null
          : renderBox.localToGlobal(Offset.zero) & renderBox.size;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(staged.file.path, mimeType: staged.mimeType)],
          title: staged.fileName,
          sharePositionOrigin: origin,
        ),
      );
      final retained = staged;
      Timer(const Duration(hours: 1), () {
        unawaited(_deleteStagedExport(retained));
      });
      staged = null;
    } catch (error) {
      _showError(error);
    } finally {
      await _deleteStagedExport(staged);
    }
  }

  Future<void> _deleteStagedExport(StagedExportFile? staged) async {
    if (staged == null) return;
    try {
      final parent = staged.file.parent;
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (_) {
      // Temporary exports are also subject to normal OS cache eviction.
    }
  }

  Future<void> _createFile() async {
    final controller = widget.controller;
    final directory = controller.currentPath;
    if (directory == null) return;

    final name = await _askForName(title: 'New file', action: 'Create');
    if (name == null || !mounted) return;

    try {
      // Reuse non-overwriting uploads; keep the directory shown when asked.
      await controller.upload(
        name: name,
        content: const Stream<List<int>>.empty(),
        length: 0,
        directory: directory,
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _createFolder() async {
    final name = await _askForName(title: 'New folder', action: 'Create');
    if (name == null) return;
    try {
      await widget.controller.createDirectory(name);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _createSymbolicLink() async {
    final name = await _askForName(title: 'New symbolic link', action: 'Next');
    if (name == null) return;
    final target = await _askForName(
      title: 'Link target for $name',
      action: 'Create',
      validateName: false,
    );
    if (target == null) return;
    try {
      await widget.controller.createSymbolicLink(name, target);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _downloadSelected() =>
      _downloadRemoteEntries(widget.controller.selectedEntries);

  Future<void> _downloadRemoteEntries(Iterable<RemoteFileEntry> entries) async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a download destination',
      );
      if (path == null) return;
      if (!mounted) return;
      final replace = await _confirm(
        title:
            'Download ${entries.length == 1 ? entries.first.name : '${entries.length} items'}?',
        message:
            'Folders are copied recursively. Existing local files are replaced.',
        confirmLabel: 'Download and Replace',
      );
      if (!replace) return;
      await widget.controller.downloadEntries(
        entries,
        Directory(path),
        overwriteExisting: true,
      );
      widget.controller.clearSelection();
      _showMessage('Download complete');
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showProperties(RemoteFileEntry entry) async {
    String? linkTarget;
    if (entry.isSymbolicLink) {
      try {
        linkTarget = await widget.controller.readSymbolicLink(entry);
      } catch (error) {
        _showError(error);
        return;
      }
    }
    if (!mounted) return;
    final mode = entry.mode == null
        ? ''
        : (entry.mode! & 0xFFF).toRadixString(8).padLeft(4, '0');
    final modeController = TextEditingController(text: mode);
    String? validationError;
    final updatedMode = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(entry.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(entry.path),
                const SizedBox(height: 12),
                Text('Type: ${entry.type.name}'),
                if (entry.size != null)
                  Text(
                    'Size: ${ghostFormatFileSize(entry.size, platform: Theme.of(context).platform)}',
                  ),
                if (entry.uid != null || entry.gid != null)
                  Text('Owner: ${entry.uid ?? '?'}:${entry.gid ?? '?'}'),
                if (entry.modifiedAt != null)
                  Text(
                    'Modified: ${ghostFormatFileModified(entry.modifiedAt, now: DateTime.now(), localeName: Localizations.localeOf(context).toString(), today: (time) => 'Today at $time', yesterday: (time) => 'Yesterday at $time')}',
                  ),
                if (linkTarget != null) ...[
                  const SizedBox(height: 8),
                  const Text('Symbolic-link target'),
                  SelectableText(linkTarget),
                ],
                if (!entry.isSymbolicLink) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: modeController,
                    decoration: InputDecoration(
                      labelText: 'Permissions (octal)',
                      hintText: '0644',
                      errorText: validationError,
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            if (!entry.isSymbolicLink)
              FilledButton(
                onPressed: () {
                  final text = modeController.text.trim();
                  final parsed = int.tryParse(text, radix: 8);
                  if (parsed == null || parsed < 0 || parsed > 0xFFF) {
                    setDialogState(() {
                      validationError =
                          'Enter an octal mode from 0000 to 7777.';
                    });
                    return;
                  }
                  Navigator.pop(context, parsed);
                },
                child: const Text('Apply mode'),
              ),
          ],
        ),
      ),
    );
    modeController.dispose();
    if (updatedMode == null ||
        (entry.mode != null && updatedMode == (entry.mode! & 0xFFF))) {
      return;
    }
    try {
      await widget.controller.setMode(entry, updatedMode);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final name = await _askForName(
      title: 'Rename ${entry.name}',
      action: 'Rename',
      initialValue: entry.name,
    );
    if (name == null) return;
    try {
      await widget.controller.renameEntry(entry, name);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    final hasLocalCopy = widget.controller.localCopies.containsKey(entry.path);
    final delete = await _confirm(
      title: 'Delete ${entry.name}?',
      message: entry.isDirectory
          ? 'Only an empty directory can be deleted. This cannot be undone.'
          : hasLocalCopy
          ? 'The remote file will be permanently deleted. Its managed local '
                'copy is retained until you upload or discard it.'
          : 'This remote file will be permanently deleted.',
      confirmLabel: 'Delete',
    );
    if (!delete) return;
    try {
      await widget.controller.deleteEntry(entry);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _enterPath() async {
    final path = await _askForName(
      title: 'Open remote path',
      action: 'Open',
      initialValue: widget.controller.currentPath,
      validateName: false,
    );
    if (path != null && path.trim().isNotEmpty) {
      await widget.controller.navigate(path.trim());
    }
  }

  Future<String?> _askForName({
    required String title,
    required String action,
    String? initialValue,
    bool validateName = true,
  }) async {
    var name = initialValue ?? '';
    String? validationError;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          // The field owns its controller through the closing animation.
          content: TextFormField(
            initialValue: initialValue,
            autofocus: true,
            onChanged: (value) => name = value,
            decoration: InputDecoration(errorText: validationError),
            onFieldSubmitted: (value) => _submitName(
              context,
              value,
              validateName,
              (message) => setDialogState(() => validationError = message),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => _submitName(
                context,
                name,
                validateName,
                (message) => setDialogState(() => validationError = message),
              ),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }

  void _submitName(
    BuildContext dialogContext,
    String value,
    bool validateName,
    ValueChanged<String?> setError,
  ) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        (validateName &&
            (trimmed == '.' || trimmed == '..' || trimmed.contains('/')))) {
      setError(validateName ? 'Enter one valid name.' : 'Enter a path.');
      return;
    }
    Navigator.pop(dialogContext, trimmed);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  void _showError(Object error) {
    if (!mounted) return;
    showTopToastIn(context, message: error.toString());
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showTopToastIn(context, message: message);
  }

  static String _safeLocalName(String name) {
    var safe = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f]'), '_');
    safe = safe.replaceFirst(RegExp(r'[. ]+$'), '_');
    if (safe.isEmpty ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
          caseSensitive: false,
        ).hasMatch(safe)) {
      return 'remote-file';
    }
    return safe;
  }

  static final bool _supportsDesktopDrop =
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static final bool _supportsSharing =
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  static String _mimeType(String name) {
    final extension = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (extension) {
      'txt' || 'log' || 'conf' || 'ini' || 'md' => 'text/plain',
      'json' => 'application/json',
      'yaml' || 'yml' => 'application/yaml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }

  static Future<void> _copyExportAtomically(File source, File target) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.seance-${uuidV4()}.part');
    final backup = File('${target.path}.seance-${uuidV4()}.backup');
    try {
      await source.copy(temporary.path);
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound)) {
        throw FileSystemException(
          'Refusing to replace a non-regular destination',
          target.path,
        );
      }
      if (type == FileSystemEntityType.file) {
        await target.rename(backup.path);
      }
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The destination is complete; a stale backup is safer than rolling
          // back a successful export after commit.
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _BrowserHeader extends StatelessWidget {
  static const _newFileAction = 'file';

  final String identity;
  final RemoteFilesController controller;
  final VoidCallback onUpload;
  final VoidCallback? onUploadFolder;
  final VoidCallback onNewFile;
  final VoidCallback onNewFolder;
  final VoidCallback onNewSymbolicLink;
  final VoidCallback onEnterPath;
  final VoidCallback onCopyPath;
  final VoidCallback onOpenTerminalHere;
  final TextEditingController filterController;
  final VoidCallback? onDownloadSelected;

  const _BrowserHeader({
    required this.identity,
    required this.controller,
    required this.onUpload,
    this.onUploadFolder,
    required this.onNewFile,
    required this.onNewFolder,
    required this.onNewSymbolicLink,
    required this.onEnterPath,
    required this.onCopyPath,
    required this.onOpenTerminalHere,
    required this.filterController,
    this.onDownloadSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                identity,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _HeaderButton(
                  tooltip: 'Up',
                  icon: Icons.arrow_upward,
                  onPressed: controller.canGoUp ? controller.goUp : null,
                ),
                _HeaderButton(
                  tooltip: 'Home',
                  icon: Icons.home,
                  hue: FamilyHue.blue,
                  onPressed: controller.goHome,
                ),
                _HeaderButton(
                  tooltip: 'Refresh',
                  icon: Icons.refresh,
                  onPressed: controller.refresh,
                ),
                Expanded(
                  child: Tooltip(
                    message: 'Open another path',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onEnterPath,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        child: Text(
                          controller.currentPath ?? 'Opening SFTP…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'File actions',
                  onSelected: (value) {
                    if (value == 'upload') onUpload();
                    if (value == 'upload_folder') onUploadFolder?.call();
                    if (value == _newFileAction) onNewFile();
                    if (value == 'folder') onNewFolder();
                    if (value == 'symlink') onNewSymbolicLink();
                    if (value == 'copy_path') onCopyPath();
                    if (value == 'terminal_here') onOpenTerminalHere();
                    if (value == 'bookmark') {
                      unawaited(controller.toggleCurrentBookmark());
                    }
                    if (value == 'hidden') {
                      controller.setShowHidden(!controller.showHidden);
                    }
                    if (value.startsWith('open_bookmark:')) {
                      unawaited(
                        controller.navigate(
                          value.substring('open_bookmark:'.length),
                        ),
                      );
                    }
                    if (value.startsWith('remove_bookmark:')) {
                      unawaited(
                        controller.removeBookmark(
                          value.substring('remove_bookmark:'.length),
                        ),
                      );
                    }
                    if (value.startsWith('sort:')) {
                      final field = RemoteSortField.values.firstWhere(
                        (field) => field.name == value.substring(5),
                      );
                      final direction =
                          controller.sortField == field &&
                              controller.sortDirection ==
                                  RemoteSortDirection.ascending
                          ? RemoteSortDirection.descending
                          : RemoteSortDirection.ascending;
                      controller.setSort(field, direction);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'upload',
                      child: Text('Upload files…'),
                    ),
                    if (onUploadFolder != null)
                      const PopupMenuItem(
                        value: 'upload_folder',
                        child: Text('Upload folder…'),
                      ),
                    PopupMenuItem(
                      value: _newFileAction,
                      enabled: controller.currentPath != null,
                      child: const Text('New file…'),
                    ),
                    const PopupMenuItem(
                      value: 'folder',
                      child: Text('New folder…'),
                    ),
                    const PopupMenuItem(
                      value: 'symlink',
                      child: Text('New symbolic link…'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'copy_path',
                      child: Text('Copy current path'),
                    ),
                    const PopupMenuItem(
                      value: 'terminal_here',
                      child: Text('Open terminal here'),
                    ),
                    PopupMenuItem(
                      value: 'bookmark',
                      child: Text(
                        controller.currentPathBookmarked
                            ? 'Remove current bookmark'
                            : 'Bookmark current path',
                      ),
                    ),
                    for (final path in controller.bookmarks) ...[
                      PopupMenuItem(
                        value: 'open_bookmark:$path',
                        child: Text(
                          'Open $path',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove_bookmark:$path',
                        child: Text(
                          'Remove bookmark $path',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'hidden',
                      child: Text(
                        controller.showHidden
                            ? 'Hide dotfiles'
                            : 'Show dotfiles',
                      ),
                    ),
                    for (final field in RemoteSortField.values)
                      PopupMenuItem(
                        value: 'sort:${field.name}',
                        child: Text(
                          'Sort by ${field.name}${controller.sortField == field
                              ? controller.sortDirection == RemoteSortDirection.ascending
                                    ? ' ↑'
                                    : ' ↓'
                              : ''}',
                        ),
                      ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: TextField(
                controller: filterController,
                onChanged: controller.setFilterQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter files',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: controller.filterQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear filter',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            filterController.clear();
                            controller.setFilterQuery('');
                          },
                        ),
                ),
              ),
            ),
            if (controller.selectedPaths.isNotEmpty)
              Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${controller.selectedPaths.length} selected'),
                  ),
                  if (onDownloadSelected != null)
                    IconButton(
                      tooltip: 'Download selected',
                      icon: Icon(
                        Icons.download,
                        color: FamilyPalette.of(context).glyph(FamilyHue.cyan),
                      ),
                      onPressed: onDownloadSelected,
                    ),
                  TextButton(
                    onPressed: controller.clearSelection,
                    child: const Text('Clear'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _BrowserFooter extends StatelessWidget {
  static const _desktopExtent = 30.0;
  static const _touchExtent = 48.0;
  static const _followLabel = 'Follow terminal directory';

  final RemoteFilesController controller;

  const _BrowserFooter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final extent = switch (theme.platform) {
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => _desktopExtent,
      _ => _touchExtent,
    };
    // Match the workspace footers, including their accessibility scaling.
    final height = MediaQuery.textScalerOf(
      context,
    ).scale(extent).clamp(extent, 4 * extent);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: MergeSemantics(
                  child: Tooltip(
                    message: _followLabel,
                    excludeFromSemantics: true,
                    child: InkWell(
                      excludeFromSemantics: true,
                      onTap: () => controller.setFollowTerminal(
                        !controller.followTerminal,
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: controller.followTerminal,
                            semanticLabel: _followLabel,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (value) =>
                                controller.setFollowTerminal(value ?? false),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: ExcludeSemantics(
                              child: Text(
                                _followLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (controller.followTerminal &&
                  controller.reportedShellDirectory == null)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message:
                        'Waiting for directory metadata from the remote shell',
                    child: Icon(Icons.info_outline, size: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    this.hue,
    this.onPressed,
  });

  /// A place's family hue (Poltergeist's D34), drawn while the button is
  /// live; navigation (Up, Refresh) keeps the button's ink.
  final FamilyHue? hue;

  @override
  Widget build(BuildContext context) {
    final hue = this.hue;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: hue == null || onPressed == null
            ? null
            : FamilyPalette.of(context).glyph(hue),
      ),
    );
  }
}

class _EditorChoice {
  final String id;
  final String label;

  const _EditorChoice(this.id, this.label);
}

/// A dense-row action icon (the ⋮ and the pending-edits badge): 16 px
/// with a 24 px ink target, sized for the desktop row's 22 px extent —
/// an [IconButton] would outgrow the row.
class _DenseActionIcon extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final void Function(Rect bounds) onPressedAt;

  const _DenseActionIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressedAt,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 500),
    child: InkWell(
      borderRadius: BorderRadius.circular(3),
      onTap: () {
        final box = context.findRenderObject() as RenderBox;
        onPressedAt(box.localToGlobal(Offset.zero) & box.size);
      },
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          icon,
          size: 15,
          color: GhostFileTheme.of(context).secondaryText,
        ),
      ),
    ),
  );
}

class _LocalCopiesPanel extends StatelessWidget {
  final List<ManagedRemoteFile> copies;
  final ValueChanged<ManagedRemoteFile> onOpen;
  final List<_EditorChoice> Function(ManagedRemoteFile) editorChoices;
  final void Function(ManagedRemoteFile, String) onOpenWith;
  final ValueChanged<ManagedRemoteFile> onUpload;
  final ValueChanged<ManagedRemoteFile> onDiscard;

  const _LocalCopiesPanel({
    required this.copies,
    required this.onOpen,
    required this.editorChoices,
    required this.onOpenWith,
    required this.onUpload,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) => ExpansionTile(
    dense: true,
    leading: const Icon(Icons.edit_document, size: 20),
    title: Text('Local edits (${copies.length})'),
    children: [
      for (final copy in copies)
        ListTile(
          dense: true,
          title: Text(remoteBasename(copy.remotePath)),
          subtitle: Text(
            '${copy.remotePath}\n${copy.missing
                ? 'Local file is missing'
                : copy.dirty
                ? 'Modified locally · review before upload'
                : 'Watching for local saves'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onOpen(copy),
          trailing: Wrap(
            children: [
              PopupMenuButton<String>(
                tooltip: 'Open with',
                enabled: !copy.missing,
                icon: const Icon(Icons.edit_outlined, size: 19),
                onSelected: (editorId) => onOpenWith(copy, editorId),
                itemBuilder: (context) => [
                  for (final editor in editorChoices(copy))
                    PopupMenuItem(value: editor.id, child: Text(editor.label)),
                ],
              ),
              IconButton(
                tooltip: 'Upload changes',
                icon: const Icon(Icons.upload, size: 19),
                onPressed: copy.missing ? null : () => onUpload(copy),
              ),
              IconButton(
                tooltip: 'Discard local copy',
                icon: const Icon(Icons.close, size: 19),
                onPressed: () => onDiscard(copy),
              ),
            ],
          ),
        ),
    ],
  );
}

class _TransfersPanel extends StatelessWidget {
  final RemoteFilesController controller;

  const _TransfersPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final palette = FamilyPalette.of(context);
    final visible = controller.transfers.reversed.take(3).toList();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              const Expanded(child: Text('Transfers')),
              TextButton(
                onPressed:
                    controller.transfers.any(
                      (item) => item.status != RemoteTransferStatus.running,
                    )
                    ? controller.clearFinishedTransfers
                    : null,
                child: const Text('Clear'),
              ),
            ],
          ),
          for (final transfer in visible)
            ListTile(
              dense: true,
              leading: Icon(
                transfer.direction == RemoteTransferDirection.upload
                    ? Icons.upload
                    : Icons.download,
                size: 19,
                color: palette.glyph(FamilyHue.cyan),
              ),
              title: Text(
                transfer.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: transfer.status == RemoteTransferStatus.running
                  ? LinearProgressIndicator(value: transfer.progress)
                  : Text(
                      switch (transfer.status) {
                        RemoteTransferStatus.completed => 'Complete',
                        RemoteTransferStatus.failed =>
                          transfer.error ?? 'Failed',
                        RemoteTransferStatus.cancelled => 'Cancelled',
                        RemoteTransferStatus.running => '',
                      },
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: transfer.status == RemoteTransferStatus.running
                  ? IconButton(
                      tooltip: 'Cancel transfer',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => controller.cancelTransfer(transfer.id),
                    )
                  // A finished transfer says how it went by colour too:
                  // done in the go green, failed or cancelled in the red.
                  : transfer.status == RemoteTransferStatus.completed
                  ? Icon(
                      Icons.check_circle,
                      size: 18,
                      color: palette.glyph(FamilyHue.green),
                    )
                  : Icon(
                      Icons.error,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
    leading: const Icon(Icons.error_outline),
    actions: [TextButton(onPressed: onRetry, child: const Text('Retry'))],
  );
}

class _FilesUnavailable extends StatelessWidget {
  final IconData icon;
  final String message;

  const _FilesUnavailable({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// Upload [copy] through [controller], confirming before it overwrites
/// remote changes that landed after the checkout. Shared by the browser's
/// upload buttons and the editor tab's save-and-upload, so both hold the
/// controller's in-flight mark that keeps the "changed locally" prompt from
/// asking about the upload's own save.
Future<bool> uploadManagedLocalCopy(
  BuildContext context,
  RemoteFilesController controller,
  ManagedRemoteFile copy, {
  bool notifySuccess = true,
}) {
  // Keyed on remotePath, not the record's id: a reconcile mid-upload swaps
  // in a record with a fresh id, and an id-keyed mark would miss it.
  return controller.trackLocalCopyUpload(
    copy.remotePath,
    () => _uploadManagedLocalCopy(
      context,
      controller,
      copy,
      notifySuccess: notifySuccess,
    ),
  );
}

Future<bool> _uploadManagedLocalCopy(
  BuildContext context,
  RemoteFilesController controller,
  ManagedRemoteFile copy, {
  required bool notifySuccess,
}) async {
  // Re-resolve the copy — a reconcile may have swapped in a newer snapshot.
  // When the controller no longer tracks the checkout at all, stop rather
  // than upload a stale record: the checkout was discarded or reconciled
  // away, and writing it would resurrect a file the user no longer manages.
  final tracked = controller.localCopies[copy.remotePath];
  if (tracked == null) {
    if (context.mounted) {
      showTopToastIn(
        context,
        message: 'No managed local copy of this file remains.',
      );
    }
    return false;
  }
  copy = tracked;
  void showError(Object error) {
    if (context.mounted) {
      showTopToastIn(context, message: error.toString());
    }
  }

  void showSuccess() {
    if (notifySuccess && context.mounted) {
      showTopToastIn(
        context,
        message: 'Uploaded ${remoteBasename(copy.remotePath)}',
      );
    }
  }

  try {
    await controller.uploadLocalCopy(copy);
    showSuccess();
    return true;
  } on RemoteFileException catch (e) {
    if (e.kind != RemoteFileErrorKind.conflict) {
      showError(e);
      return false;
    }
    if (!context.mounted) return false;
    final overwrite =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remote file changed'),
            content: Text(
              '${e.message}\n\nOverwrite the newer remote version?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        ) ??
        false;
    if (!overwrite) return false;
    try {
      await controller.uploadLocalCopy(copy, overwriteRemoteChanges: true);
      showSuccess();
      return true;
    } catch (failure) {
      showError(failure);
      return false;
    }
  } catch (e) {
    showError(e);
    return false;
  }
}

/// One editor tab's content: the built-in editor wired to whichever session
/// currently owns the file's checkout. The owner is resolved fresh each
/// build — a reconnect swaps the session object under the tab, and a dropped
/// connection turns upload/drift off without touching the local copy.
class EditorTabView extends StatelessWidget {
  final EditorTab tab;
  final AppState state;
  final bool isActive;

  const EditorTabView({
    super.key,
    required this.tab,
    required this.state,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final owner = state.ownerSessionFor(tab);
    final files = owner?.files;
    return BuiltInTextEditorScreen(
      key: tab.editorKey,
      file: state.services.managedRemoteFiles.checkoutFile(tab.localPath),
      remotePath: tab.remotePath,
      isActive: isActive,
      remoteFiles: files,
      dirtyNotifier: tab.dirty,
      onSaved: () => _reconcileAfterSave(owner),
      onUpload: files == null
          ? null
          : () async {
              final copy = files.localCopies[tab.remotePath];
              if (copy == null) {
                showTopToastIn(
                  context,
                  message: 'No managed local copy of this file remains.',
                );
                return false;
              }
              // The editor reports "Saved and uploaded" itself.
              return uploadManagedLocalCopy(
                context,
                files,
                copy,
                notifySuccess: false,
              );
            },
    );
  }

  /// After a save: refresh the owning controller's copy bookkeeping — or the
  /// retained-copy map when the session is offline.
  Future<void> _reconcileAfterSave(TerminalSession? owner) async {
    final files = owner?.files;
    if (files != null) {
      await files.reconcileLocalCopies();
      return;
    }
    if (owner == null) return;
    final copy = owner.retainedLocalCopies[tab.remotePath];
    if (copy != null) {
      await state.reconcileRetainedLocalCopy(owner.id, copy);
    }
  }
}

class _RecoveredLocalEdits extends StatelessWidget {
  final TerminalSession session;
  final AppState state;

  /// True when this pane lives on a pushed route (the narrow layout's
  /// [FilesScreen]): opening an editor tab pops it out of the way.
  final bool popAfterTerminalStage;

  const _RecoveredLocalEdits({
    required this.session,
    required this.state,
    this.popAfterTerminalStage = false,
  });

  @override
  Widget build(BuildContext context) {
    final copies = session.retainedLocalCopies.values.toList();
    return Column(
      children: [
        MaterialBanner(
          leading: const Icon(Icons.cloud_off_outlined),
          content: const Text(
            'These local edits were recovered. Reconnect before uploading; '
            'Open and Discard remain available offline.',
          ),
          actions: [
            TextButton(
              onPressed: () => state.reconnect(session.id),
              child: const Text('Reconnect'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: copies.length,
            itemBuilder: (context, index) {
              final copy = copies[index];
              return ListTile(
                leading: Icon(
                  copy.missing
                      ? Icons.file_present_outlined
                      : Icons.edit_document,
                ),
                title: Text(remoteBasename(copy.remotePath)),
                subtitle: Text(
                  copy.missing
                      ? 'Local checkout is missing'
                      : copy.dirty
                      ? '${copy.remotePath}\nModified locally'
                      : copy.remotePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: copy.missing
                    ? null
                    : () => _open(context, copy),
                trailing: Wrap(
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Open with',
                      enabled: !copy.missing,
                      icon: const Icon(Icons.edit_outlined),
                      onSelected: (editorId) => _open(context, copy, editorId),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: EditorRegistry.builtInId,
                          child: Text('Built-in text editor'),
                        ),
                        if (currentEditorHostPlatform != null)
                          const PopupMenuItem(
                            value: EditorRegistry.systemDefaultId,
                            child: Text('System default'),
                          ),
                        for (final editor
                            in state.services.settings.editorRegistry
                                .compatibleEditors(copy.remotePath))
                          PopupMenuItem(
                            value: editor.id,
                            child: Text(editor.displayName),
                          ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Discard local copy',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _discard(context, copy),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Opens [copy] in [editorId], or in the default editor when null.
  Future<void> _open(
    BuildContext context,
    ManagedRemoteFile copy, [
    String? editorId,
  ]) async {
    try {
      final registry = state.services.settings.editorRegistry;
      final file = state.services.managedRemoteFiles.checkoutFile(
        copy.localPath,
      );
      final selected =
          editorId ??
          await registry.effectiveDefaultForCheckout(copy.remotePath, file);
      if (selected == EditorRegistry.builtInId) {
        // A tab beside the terminals, like the live browser's open — the
        // checkout keeps the placeholder session's edit identity, so the tab
        // lands on it.
        state.openEditorTab(copy);
        // On the pushed Files route (the narrow layout) the new tab is
        // underneath this screen, so get out of its way.
        if (popAfterTerminalStage && context.mounted) {
          Navigator.of(context).pop();
        }
        return;
      }
      if (selected == EditorRegistry.systemDefaultId) {
        await const ExternalFileOpener().openSystemDefault(file.path);
      } else {
        final editor = registry.byId(selected);
        if (editor == null) {
          throw StateError('The selected editor no longer exists.');
        }
        await const ExternalFileOpener().openWith(file.path, editor);
      }
    } catch (error) {
      if (!context.mounted) return;
      showTopToastIn(context, message: error.toString());
    }
  }

  Future<void> _discard(BuildContext context, ManagedRemoteFile copy) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard local copy?'),
        content: const Text(
          'Any changes not uploaded to the server are deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true) {
      await state.discardRetainedLocalCopy(session.id, copy);
    }
  }
}

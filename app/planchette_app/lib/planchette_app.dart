import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace.dart';

class PlanchetteApp extends StatelessWidget {
  const PlanchetteApp({
    super.key,
    required this.workspace,
    this.navigatorKey,
    this.onQuit,
    this.themeMode = ThemeMode.system,
  });

  final DocumentWorkspace workspace;
  final GlobalKey<NavigatorState>? navigatorKey;
  final Future<void> Function()? onQuit;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Planchette',
    navigatorKey: navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: themeMode,
    home: _DocumentShell(workspace: workspace, onQuit: onQuit),
  );

  ThemeData _theme(Brightness brightness) => ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff245b5c),
      brightness: brightness,
    ),
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
  );
}

class _DocumentShell extends StatefulWidget {
  const _DocumentShell({required this.workspace, this.onQuit});
  final DocumentWorkspace workspace;
  final Future<void> Function()? onQuit;

  @override
  State<_DocumentShell> createState() => _DocumentShellState();
}

class _DocumentShellState extends State<_DocumentShell> {
  DocumentWorkspace get workspace => widget.workspace;
  bool get mac => defaultTargetPlatform == TargetPlatform.macOS;
  FocusNode? _lastTextFocus;

  /// The one readiness rule behind every document command and the toolbar.
  /// [DocumentWorkspace] refuses edits and saves for a tab that is still
  /// loading or that failed to load, so a control offering them anyway would
  /// accept the click and silently do nothing.
  bool get _documentReady {
    final tab = workspace.active;
    return tab != null &&
        !workspace.interactionLocked &&
        !tab.busy &&
        !tab.editor.isLoading &&
        tab.editor.error == null;
  }

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    FocusManager.instance.addListener(_rememberTextFocus);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _rememberTextFocus() {
    final focus = FocusManager.instance.primaryFocus;
    final tab = workspace.active;
    if (tab != null &&
        (focus == tab.editor.editorFocus ||
            focus == tab.editor.searchFocus ||
            focus == tab.editor.replacementFocus)) {
      _lastTextFocus = focus;
    }
  }

  void _textAction(Intent intent) {
    if (workspace.interactionLocked) return;
    final tab = workspace.active;
    if (tab == null) return;
    final remembered = _lastTextFocus;
    final target =
        remembered != null &&
            [
              tab.editor.editorFocus,
              tab.editor.searchFocus,
              tab.editor.replacementFocus,
            ].contains(remembered)
        ? remembered
        : tab.editor.editorFocus;
    final context = target.context;
    if (context == null) return;
    target.requestFocus();
    Actions.maybeInvoke(context, intent);
  }

  void _save({bool saveAs = false}) {
    final tab = workspace.active;
    if (tab != null) unawaited(workspace.save(tab, saveAs: saveAs));
  }

  void _close() {
    final tab = workspace.active;
    if (tab != null) unawaited(workspace.closeTab(tab));
  }

  void _new() {
    final tab = workspace.newDocument();
    if (tab != null) _focusAfterFrame(tab);
  }

  void _focusAfterFrame(DocumentTab tab) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && workspace.active == tab && !workspace.interactionLocked) {
        tab.editor.editorFocus.requestFocus();
      }
    });
  }

  void _select(DocumentTab tab) {
    workspace.select(tab);
    _focusAfterFrame(tab);
  }

  void _nextTab({bool previous = false}) {
    final tabs = workspace.documents;
    if (tabs.isEmpty || workspace.interactionLocked) return;
    final active = workspace.active;
    if (active == null) {
      _select(tabs.first);
      return;
    }
    final index = tabs.indexOf(active);
    _select(tabs[(index + (previous ? -1 : 1)) % tabs.length]);
  }

  void _find({bool replace = false}) {
    if (!workspace.interactionLocked) {
      workspace.active?.editor.openSearch(replace: replace);
    }
  }

  SingleActivator _shortcut(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) => SingleActivator(key, meta: mac, control: !mac, shift: shift, alt: alt);

  List<_ShellMenu> _menus() {
    final active = workspace.active;
    final unlocked = !workspace.interactionLocked;
    final ready = _documentReady;
    // The tab's × closes whenever a save isn't in flight — including during
    // load or after a load error — so the menu command follows the same rule.
    final closable = active != null && unlocked && !active.busy;
    return [
      _ShellMenu('File', [
        _Command(
          'New',
          _new,
          shortcut: _shortcut(LogicalKeyboardKey.keyN),
          enabled: unlocked,
        ),
        _Command(
          'Open…',
          () => unawaited(workspace.openDialog()),
          shortcut: _shortcut(LogicalKeyboardKey.keyO),
          enabled: unlocked,
        ),
        const _Separator(),
        _Command(
          'Save',
          _save,
          shortcut: _shortcut(LogicalKeyboardKey.keyS),
          enabled: ready,
        ),
        _Command(
          'Save As…',
          () => _save(saveAs: true),
          shortcut: _shortcut(LogicalKeyboardKey.keyS, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          'Close Tab',
          _close,
          shortcut: _shortcut(LogicalKeyboardKey.keyW),
          enabled: closable,
        ),
        if (!mac && widget.onQuit != null) ...[
          const _Separator(),
          _Command(
            'Quit',
            () => unawaited(widget.onQuit!()),
            shortcut: _shortcut(LogicalKeyboardKey.keyQ),
            enabled: unlocked,
          ),
        ],
      ]),
      _ShellMenu('Edit', [
        _Command(
          'Undo',
          () =>
              _textAction(const UndoTextIntent(SelectionChangedCause.keyboard)),
          shortcut: _shortcut(LogicalKeyboardKey.keyZ),
          enabled: ready,
        ),
        _Command(
          'Redo',
          () =>
              _textAction(const RedoTextIntent(SelectionChangedCause.keyboard)),
          shortcut: _shortcut(LogicalKeyboardKey.keyZ, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          'Cut',
          () => _textAction(
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyX),
          enabled: ready,
        ),
        _Command(
          'Copy',
          () => _textAction(CopySelectionTextIntent.copy),
          shortcut: _shortcut(LogicalKeyboardKey.keyC),
          enabled: ready,
        ),
        _Command(
          'Paste',
          () => _textAction(
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyV),
          enabled: ready,
        ),
        _Command(
          'Select All',
          () => _textAction(
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyA),
          enabled: ready,
        ),
      ]),
      _ShellMenu('Find', [
        _Command(
          'Find…',
          _find,
          shortcut: _shortcut(LogicalKeyboardKey.keyF),
          enabled: ready,
        ),
        _Command(
          'Replace…',
          () => _find(replace: true),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyF, alt: true)
              : _shortcut(LogicalKeyboardKey.keyH),
          enabled: ready,
        ),
        _Command(
          'Find Next',
          () => active?.editor.nextMatch(),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG)
              : const SingleActivator(LogicalKeyboardKey.f3),
          enabled: ready,
        ),
        _Command(
          'Find Previous',
          () => active?.editor.previousMatch(),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG, shift: true)
              : const SingleActivator(LogicalKeyboardKey.f3, shift: true),
          enabled: ready,
        ),
      ]),
      _ShellMenu('Window', [
        _Command(
          'Next Tab',
          _nextTab,
          shortcut: const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
          ),
          enabled: unlocked && workspace.documents.length > 1,
        ),
        _Command(
          'Previous Tab',
          () => _nextTab(previous: true),
          shortcut: const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
            shift: true,
          ),
          enabled: unlocked && workspace.documents.length > 1,
        ),
      ]),
    ];
  }

  List<PlatformMenuItem> _nativeItems(List<_MenuEntry> entries) {
    final groups = <PlatformMenuItem>[];
    var group = <PlatformMenuItem>[];
    void flush() {
      if (group.isEmpty) return;
      groups.add(PlatformMenuItemGroup(members: group));
      group = [];
    }

    for (final entry in entries) {
      if (entry is _Separator) {
        flush();
        continue;
      }
      final command = entry as _Command;
      group.add(
        PlatformMenuItem(
          label: command.label,
          shortcut: command.shortcut,
          onSelected: command.enabled ? command.run : null,
        ),
      );
    }
    flush();
    return groups;
  }

  Widget _nativeMenu(List<_ShellMenu> menus, Widget child) => PlatformMenuBar(
    menus: [
      PlatformMenu(
        label: 'Planchette',
        menus: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
            ],
          ),
          PlatformMenuItem(
            label: 'Quit Planchette',
            shortcut: _shortcut(LogicalKeyboardKey.keyQ),
            onSelected: widget.onQuit == null
                ? null
                : () => unawaited(widget.onQuit!()),
          ),
        ],
      ),
      for (final menu in menus)
        PlatformMenu(
          label: menu.label,
          menus: [
            ..._nativeItems(menu.items),
            if (menu.label == 'Window') ...const [
              PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.minimizeWindow,
                  ),
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.zoomWindow,
                  ),
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
                  ),
                ],
              ),
            ],
          ],
        ),
    ],
    child: child,
  );

  Widget _menuBar(List<_ShellMenu> menus) => MenuBar(
    style: MenuStyle(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(
        Theme.of(context).colorScheme.surface,
      ),
    ),
    children: [
      for (final menu in menus)
        SubmenuButton(
          menuChildren: [
            for (final entry in menu.items)
              if (entry is _Separator)
                const Divider(height: 8)
              else if (entry is _Command)
                MenuItemButton(
                  onPressed: entry.enabled ? entry.run : null,
                  shortcut: entry.shortcut,
                  child: Text(entry.label),
                ),
          ],
          child: Text(menu.label),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final menus = _menus();
    final tabs = workspace.documents;
    final active = workspace.active;
    final scheme = Theme.of(context).colorScheme;
    final shortcuts = <ShortcutActivator, VoidCallback>{
      for (final menu in menus)
        for (final entry in menu.items)
          if (entry is _Command &&
              entry.shortcut != null &&
              menu.label != 'Edit')
            entry.shortcut!: () {
              if (entry.enabled) entry.run();
            },
    };
    Widget body = CallbackShortcuts(
      bindings: shortcuts,
      // Keep focus below the shortcuts when the final editor is disposed.
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              if (!mac) _menuBar(menus),
              Material(
                color: scheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_rounded, color: scheme.primary),
                      const SizedBox(width: 8),
                      const Text(
                        'Planchette',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                        tooltip: 'New',
                        onPressed: workspace.interactionLocked ? null : _new,
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: 'Open…',
                        onPressed: workspace.interactionLocked
                            ? null
                            : () => unawaited(workspace.openDialog()),
                        icon: const Icon(Icons.folder_open_outlined),
                      ),
                      IconButton(
                        tooltip: 'Save',
                        onPressed: _documentReady ? _save : null,
                        icon: const Icon(Icons.save_outlined),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        // A full path is more useful than a bare name here —
                        // which directory is open is worth knowing — but it
                        // truncates on narrow windows, so the tooltip carries
                        // the whole thing.
                        child: Tooltip(
                          message: active?.path ?? '',
                          child: Text(
                            // `path` and `name` are null or non-empty by
                            // construction: `name` is 'Untitled <id>' or
                            // basename of a normalised path, and a directory
                            // can never become a document path.
                            active?.path ??
                                active?.name ??
                                'A place for your words.',
                            key: const ValueKey('active-document-label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      if (active?.busy == true)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              ),
              if (tabs.isNotEmpty)
                Material(
                  color: scheme.surfaceContainerLow,
                  child: SizedBox(
                    height: 40,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          for (final tab in tabs)
                            _TabChip(
                              key: ValueKey('tab-${tab.id}'),
                              tab: tab,
                              isActive: tab == active,
                              enabled: !workspace.interactionLocked,
                              onSelect: () => _select(tab),
                              onClose: () => unawaited(workspace.closeTab(tab)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (workspace.error case final error?)
                Material(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            error,
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Dismiss error',
                          onPressed: workspace.clearError,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: tabs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.description_outlined,
                              size: 48,
                              color: scheme.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Start with a blank page',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton(
                                  onPressed: _new,
                                  child: const Text('New document'),
                                ),
                                const SizedBox(width: 12),
                                OutlinedButton(
                                  onPressed: () =>
                                      unawaited(workspace.openDialog()),
                                  child: const Text('Open…'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : IndexedStack(
                        index: tabs.indexOf(active!),
                        children: [
                          for (final tab in tabs)
                            PlanchetteEditor(
                              key: ValueKey(tab.id),
                              controller: tab.editor,
                              isActive: tab == active,
                              editingLocked: workspace.interactionLocked,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mac) body = _nativeMenu(menus, body);
    return body;
  }

  @override
  void dispose() {
    workspace.removeListener(_changed);
    FocusManager.instance.removeListener(_rememberTextFocus);
    super.dispose();
  }
}

/// One document tab.
///
/// Opening a document the workspace already holds activates its tab instead
/// of adding one, which looks like nothing happening. [DocumentTab.flashRequest]
/// marks that case, and the chip answers with a short pulse so the user can
/// see where the open landed. The pulse is decoration: activation happens
/// either way, and it is skipped entirely when the platform reports that
/// animation is disabled.
class _TabChip extends StatefulWidget {
  const _TabChip({
    super.key,
    required this.tab,
    required this.isActive,
    required this.enabled,
    required this.onSelect,
    required this.onClose,
  });

  final DocumentTab tab;
  final bool isActive;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  /// Long enough to notice between two glances, short enough not to linger.
  static const _flashDuration = Duration(milliseconds: 700);

  bool _flashing = false;

  /// The last flash request this chip reacted to. Zero is also the value a
  /// freshly mounted tab has, and a new tab has nothing to point at.
  int _seenFlash = 0;
  Timer? _flashTimer;

  @override
  void didUpdateWidget(_TabChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Compare against the value this state last saw, not against
    // oldWidget.tab: the tab is a mutable object, so the old widget reads the
    // new value too and the request would look unchanged.
    if (widget.tab.flashRequest == _seenFlash) return;
    _seenFlash = widget.tab.flashRequest;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _flashTimer?.cancel();
    // No setState: didUpdateWidget is followed immediately by this element's
    // own build, which is the frame the flash should first appear in. Only the
    // timer needs a new frame, to take it away again.
    _flashing = true;
    _flashTimer = Timer(_flashDuration, () {
      if (mounted) setState(() => _flashing = false);
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final scheme = Theme.of(context).colorScheme;
    final base = widget.isActive ? scheme.surface : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: tab.path ?? tab.name,
        child: Semantics(
          selected: widget.isActive,
          child: AnimatedContainer(
            duration: _flashDuration,
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: _flashing ? scheme.secondaryContainer : base,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.enabled ? widget.onSelect : null,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: [
                      Text(
                        '${tab.editor.isDirty ? '● ' : ''}${tab.name}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: ValueKey('close-${tab.id}'),
                        tooltip: 'Close ${tab.name}',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        onPressed: widget.enabled && !tab.busy
                            ? widget.onClose
                            : null,
                        icon: const Icon(Icons.close),
                      ),
                    ],
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

class _ShellMenu {
  const _ShellMenu(this.label, this.items);
  final String label;
  final List<_MenuEntry> items;
}

sealed class _MenuEntry {
  const _MenuEntry();
}

final class _Separator extends _MenuEntry {
  const _Separator();
}

final class _Command extends _MenuEntry {
  const _Command(this.label, this.run, {this.shortcut, this.enabled = true});
  final String label;
  final VoidCallback run;
  final SingleActivator? shortcut;
  final bool enabled;
}

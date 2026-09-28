import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace.dart';
import 'theme/planchette_theme.dart';
import 'widgets/tab_strip.dart';

/// The color the native window shows before the first Flutter frame. Must be
/// the same surface the app paints, or the window flashes a different color on
/// the way in.
Color windowBackdrop(Brightness brightness) =>
    planchetteTheme(brightness).scaffoldBackgroundColor;

/// Resolves the theme mode to the brightness the app will actually paint with,
/// so the window backdrop and the theme cannot disagree. Read the system
/// brightness through `PlatformDispatcher`, which needs no binding, because the
/// window is created before `runApp`.
///
/// A future persisted theme (A1) has to be resolved here, before the window
/// exists: passing one mode to [PlanchetteApp] and another here would bring the
/// flash straight back.
Brightness effectiveBrightness(ThemeMode mode) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => PlatformDispatcher.instance.platformBrightness,
};

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
    theme: planchetteTheme(Brightness.light),
    darkTheme: planchetteTheme(Brightness.dark),
    themeMode: themeMode,
    home: _DocumentShell(workspace: workspace, onQuit: onQuit),
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

  /// Editor font sizes for View › Zoom. The default is the editor's own 14.
  static const _zoomSizes = [
    9.0,
    10.0,
    11.0,
    12.0,
    13.0,
    14.0,
    16.0,
    18.0,
    20.0,
    22.0,
    24.0,
    28.0,
    32.0,
    36.0,
    48.0,
  ];
  static const _defaultZoom = 5;
  int _zoom = _defaultZoom;

  void _setZoom(int zoom) {
    final next = zoom.clamp(0, _zoomSizes.length - 1);
    if (next != _zoom) setState(() => _zoom = next);
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
    if (tab != null && tab.editor.textFocusNodes.contains(focus)) {
      _lastTextFocus = focus;
    }
  }

  void _textAction(Intent intent) {
    if (workspace.interactionLocked) return;
    final tab = workspace.active;
    if (tab == null) return;
    final remembered = _lastTextFocus;
    final target =
        remembered != null && tab.editor.textFocusNodes.contains(remembered)
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

  void _saveAll() => unawaited(workspace.saveAll());

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
        tab.editor.restoreFocus();
      }
    });
  }

  void _select(DocumentTab tab) {
    workspace.select(tab);
    _focusAfterFrame(tab);
  }

  /// Cmd/Ctrl+1…8 select that tab and 9 the last one, as in browsers.
  void _selectNumbered(int number) {
    final tabs = workspace.documents;
    if (tabs.isEmpty || workspace.interactionLocked) return;
    if (number == 9) {
      _select(tabs.last);
    } else if (number <= tabs.length) {
      _select(tabs[number - 1]);
    }
  }

  String _keyLabel(String key) => mac ? '⌘$key' : 'Ctrl+$key';

  void _showTabMenu(Offset position, DocumentTab tab) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final hasOthers = workspace.documents.length > 1;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          enabled: !workspace.interactionLocked && !tab.busy,
          onTap: () => unawaited(workspace.closeTab(tab)),
          child: const Text('Close'),
        ),
        PopupMenuItem(
          enabled: hasOthers && !workspace.interactionLocked,
          onTap: () => unawaited(workspace.closeOthers(tab)),
          child: const Text('Close Others'),
        ),
        PopupMenuItem(
          enabled: hasOthers && !workspace.interactionLocked,
          onTap: () => unawaited(workspace.closeAllTabs()),
          child: const Text('Close All Tabs'),
        ),
      ],
    );
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
    // The tab's × is available whenever no save is in flight and the
    // workspace isn't interaction-locked — including during load or after
    // a load error — so the menu command follows the same rule.
    final closable = active != null && unlocked && !active.busy;
    // A composing input method or a host lock refuses line edits too.
    final lineCommands = ready && (active?.editor.canEditText ?? false);
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
        _Command(
          'Save All',
          _saveAll,
          shortcut: _shortcut(LogicalKeyboardKey.keyS, alt: true),
          enabled:
              unlocked && workspace.documents.any((tab) => tab.editor.isDirty),
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
        const _Separator(),
        _Command(
          'Duplicate Line',
          () => active?.editor.duplicateLines(),
          shortcut: _shortcut(LogicalKeyboardKey.keyD, shift: true),
          enabled: lineCommands,
        ),
        _Command(
          'Move Line Up',
          () => active?.editor.moveLines(LineDirection.up),
          shortcut: const SingleActivator(
            LogicalKeyboardKey.arrowUp,
            alt: true,
          ),
          enabled: lineCommands,
        ),
        _Command(
          'Move Line Down',
          () => active?.editor.moveLines(LineDirection.down),
          shortcut: const SingleActivator(
            LogicalKeyboardKey.arrowDown,
            alt: true,
          ),
          enabled: lineCommands,
        ),
        _Command(
          'Delete Line',
          () => active?.editor.deleteLines(),
          shortcut: _shortcut(LogicalKeyboardKey.keyK, shift: true),
          enabled: lineCommands,
        ),
        _Command(
          'Join Lines',
          () => active?.editor.joinLines(),
          shortcut: _shortcut(LogicalKeyboardKey.keyJ),
          enabled: lineCommands,
        ),
        const _Separator(),
        _Command(
          'Toggle Comment',
          () => active?.editor.toggleComment(),
          shortcut: _shortcut(LogicalKeyboardKey.slash),
          enabled: ready && (active?.editor.canToggleComment ?? false),
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
        const _Separator(),
        _Command(
          'Go to Matching Bracket',
          () => active?.editor.goToMatchingBracket(),
          shortcut: _shortcut(LogicalKeyboardKey.keyB),
          enabled: ready,
        ),
        _Command(
          'Select to Matching Bracket',
          () => active?.editor.goToMatchingBracket(extend: true),
          shortcut: _shortcut(LogicalKeyboardKey.keyB, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          'Go to Line…',
          () => workspace.active?.editor.openGoToLine(),
          shortcut: _shortcut(
            mac ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.keyG,
          ),
          enabled: ready,
        ),
      ]),
      _ShellMenu('View', [
        _Command(
          'Zoom In',
          () => _setZoom(_zoom + 1),
          shortcut: _shortcut(LogicalKeyboardKey.equal),
          // `+` sits on different keys, shifted or not, across layouts.
          aliases: [
            _shortcut(LogicalKeyboardKey.equal, shift: true),
            _shortcut(LogicalKeyboardKey.add),
            _shortcut(LogicalKeyboardKey.add, shift: true),
            _shortcut(LogicalKeyboardKey.numpadAdd),
          ],
          enabled: _zoom < _zoomSizes.length - 1,
        ),
        _Command(
          'Zoom Out',
          () => _setZoom(_zoom - 1),
          shortcut: _shortcut(LogicalKeyboardKey.minus),
          aliases: [_shortcut(LogicalKeyboardKey.numpadSubtract)],
          enabled: _zoom > 0,
        ),
        _Command(
          'Actual Size',
          () => _setZoom(_defaultZoom),
          shortcut: _shortcut(LogicalKeyboardKey.digit0),
          aliases: [_shortcut(LogicalKeyboardKey.numpad0)],
          enabled: _zoom != _defaultZoom,
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
            for (final shortcut in [entry.shortcut!, ...entry.aliases])
              shortcut: () {
                if (entry.enabled) entry.run();
              },
      for (var number = 1; number <= 9; number++)
        _shortcut(_digits[number]): () => _selectNumbered(number),
    };
    Widget body = CallbackShortcuts(
      bindings: shortcuts,
      // Keep focus below the shortcuts when the final editor is disposed.
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: Column(
            // Chrome rows span the window and start at the leading edge;
            // a centered column floated the menu bar mid-window.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!mac) _menuBar(menus),
              TabStrip(
                tabs: [
                  for (final tab in tabs)
                    (
                      id: tab.id,
                      name: workspace.labelFor(tab),
                      tooltip: tab.path ?? tab.name,
                      dirty: tab.editor.isDirty,
                      closable: !tab.busy,
                      flashRequest: tab.flashRequest,
                    ),
                ],
                activeId: active?.id,
                enabled: !workspace.interactionLocked,
                busy: active?.busy == true,
                onSelect: (id) => _select(tabs.firstWhere((t) => t.id == id)),
                onClose: (id) => unawaited(
                  workspace.closeTab(tabs.firstWhere((t) => t.id == id)),
                ),
                onContextMenu: (id, position) =>
                    _showTabMenu(position, tabs.firstWhere((t) => t.id == id)),
                onNew: _new,
                onOpen: () => unawaited(workspace.openDialog()),
                onSave: _documentReady ? _save : null,
                newTooltip: 'New (${_keyLabel('N')})',
                openTooltip: 'Open… (${_keyLabel('O')})',
                saveTooltip: 'Save (${_keyLabel('S')})',
              ),
              if (workspace.error case final error?)
                Semantics(
                  key: const ValueKey('workspace-error-banner'),
                  liveRegion: true,
                  child: Material(
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
                              textStyle: TextStyle(fontSize: _zoomSizes[_zoom]),
                              controller: tab.editor,
                              isActive: tab == active,
                              // No editingLocked here: the workspace locks
                              // each controller the moment a dialog opens
                              // and unlocks it the moment it closes. A view
                              // lock would clear only on the next rebuild,
                              // refusing a save made before it.
                              //
                              // A locked field cannot take the typing the
                              // placeholder invites.
                              placeholder:
                                  tab.path == null &&
                                      !workspace.interactionLocked
                                  ? ghostLineFor(tab.id)
                                  : null,
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

/// What an untitled document shows while it is empty. Each line leads with
/// the instruction, which is what a screen reader announces first; the rest
/// is the board talking.
const _ghostLines = [
  'Start typing. The spirits are listening…',
  'Start typing. The board is waiting…',
  'Start typing. Something wants to be written…',
  'Start typing. Rest a finger on the planchette…',
  'Start typing. Ask, and it will answer…',
];

/// The ghost line for a tab: fixed for that tab, and different for the tab
/// created right after it.
@visibleForTesting
String ghostLineFor(int tabId) => _ghostLines[tabId % _ghostLines.length];

const _digits = [
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

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
  const _Command(
    this.label,
    this.run, {
    this.shortcut,
    this.aliases = const [],
    this.enabled = true,
  });
  final String label;
  final VoidCallback run;
  final SingleActivator? shortcut;

  /// More key combinations for the same command, not shown in menus.
  final List<SingleActivator> aliases;
  final bool enabled;
}

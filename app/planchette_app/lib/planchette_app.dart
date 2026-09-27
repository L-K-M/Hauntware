import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace.dart';
import 'widgets/tab_strip.dart';

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

  void _nextTab({bool previous = false}) {
    final tabs = workspace.documents;
    if (tabs.isEmpty || workspace.interactionLocked) return;
    final index = tabs.indexOf(workspace.active!);
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
    final ready =
        active != null &&
        unlocked &&
        !active.busy &&
        !active.editor.isLoading &&
        active.editor.error == null;
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
          enabled: ready,
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
                      name: tab.name,
                      tooltip: tab.path ?? tab.name,
                      dirty: tab.editor.isDirty,
                      closable: !tab.busy,
                    ),
                ],
                activeId: active?.id,
                enabled: !workspace.interactionLocked,
                busy: active?.busy == true,
                onSelect: (id) => _select(tabs.firstWhere((t) => t.id == id)),
                onClose: (id) => unawaited(
                  workspace.closeTab(tabs.firstWhere((t) => t.id == id)),
                ),
                onNew: _new,
                onOpen: () => unawaited(workspace.openDialog()),
                onSave:
                    active == null || active.busy || workspace.interactionLocked
                    ? null
                    : _save,
                newTooltip: 'New (${_keyLabel('N')})',
                openTooltip: 'Open… (${_keyLabel('O')})',
                saveTooltip: 'Save (${_keyLabel('S')})',
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
  const _Command(this.label, this.run, {this.shortcut, this.enabled = true});
  final String label;
  final VoidCallback run;
  final SingleActivator? shortcut;
  final bool enabled;
}

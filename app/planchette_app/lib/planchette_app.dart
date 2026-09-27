import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/app_settings.dart';
import 'services/document_workspace.dart';
import 'services/settings_dialog.dart';

class PlanchetteApp extends StatelessWidget {
  const PlanchetteApp({
    super.key,
    required this.workspace,
    required this.settings,
    this.navigatorKey,
    this.onQuit,
    this.strings = const ShellStrings(),
  });

  final DocumentWorkspace workspace;

  /// The user's choices, and the only place the theme and text size come from.
  final SettingsController settings;
  final GlobalKey<NavigatorState>? navigatorKey;
  final Future<void> Function()? onQuit;
  final ShellStrings strings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => MaterialApp(
      title: strings.appName,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: settings.value.themeMode,
      home: _DocumentShell(
        workspace: workspace,
        settings: settings,
        onQuit: onQuit,
        strings: strings,
      ),
    ),
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
  const _DocumentShell({
    required this.workspace,
    required this.settings,
    this.onQuit,
    this.strings = const ShellStrings(),
  });
  final DocumentWorkspace workspace;
  final SettingsController settings;
  final Future<void> Function()? onQuit;
  final ShellStrings strings;

  @override
  State<_DocumentShell> createState() => _DocumentShellState();
}

class _DocumentShellState extends State<_DocumentShell> {
  DocumentWorkspace get workspace => widget.workspace;
  SettingsController get settings => widget.settings;
  ShellStrings get strings => widget.strings;
  bool get mac => defaultTargetPlatform == TargetPlatform.macOS;
  FocusNode? _lastTextFocus;

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    FocusManager.instance.addListener(_rememberTextFocus);
    _applySettings();
  }

  /// Push the user's choices into every open buffer, and keep pushing them for
  /// documents opened later.
  void _applySettings() {
    final value = settings.value;
    for (final tab in workspace.documents) {
      tab.editor.indent = value.indent;
    }
    settings.addListener(_settingsChanged);
  }

  void _settingsChanged() {
    final value = settings.value;
    for (final tab in workspace.documents) {
      tab.editor.indent = value.indent;
    }
    if (mounted) setState(() {});
  }

  TextStyle get _textStyle => TextStyle(
    fontFamily: settings.value.fontFamily,
    fontFamilyFallback: settings.value.fontFamily == null
        ? const ['monospace', 'Menlo', 'Consolas', 'DejaVu Sans Mono']
        : const ['monospace'],
    fontSize: settings.value.fontSize.toDouble(),
    height: 1.35,
  );

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

  void _showSettings() {
    unawaited(
      SettingsDialog.show(context, settings: settings, strings: strings),
    );
  }

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
      _ShellMenu(strings.file, [
        _Command(
          strings.newDocument,
          _new,
          shortcut: _shortcut(LogicalKeyboardKey.keyN),
          enabled: unlocked,
        ),
        _Command(
          strings.openDocument,
          () => unawaited(workspace.openDialog()),
          shortcut: _shortcut(LogicalKeyboardKey.keyO),
          enabled: unlocked,
        ),
        const _Separator(),
        _Command(
          strings.save,
          _save,
          shortcut: _shortcut(LogicalKeyboardKey.keyS),
          enabled: ready,
        ),
        _Command(
          strings.saveAs,
          () => _save(saveAs: true),
          shortcut: _shortcut(LogicalKeyboardKey.keyS, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          strings.settings,
          _showSettings,
          shortcut: _shortcut(LogicalKeyboardKey.comma),
          enabled: unlocked,
        ),
        _Command(
          strings.closeTab,
          _close,
          shortcut: _shortcut(LogicalKeyboardKey.keyW),
          enabled: ready,
        ),
        if (!mac && widget.onQuit != null) ...[
          const _Separator(),
          _Command(
            strings.quit,
            () => unawaited(widget.onQuit!()),
            shortcut: _shortcut(LogicalKeyboardKey.keyQ),
            enabled: unlocked,
          ),
        ],
      ]),
      _ShellMenu(strings.edit, [
        _Command(
          strings.undo,
          () =>
              _textAction(const UndoTextIntent(SelectionChangedCause.keyboard)),
          shortcut: _shortcut(LogicalKeyboardKey.keyZ),
          enabled: ready,
        ),
        _Command(
          strings.redo,
          () =>
              _textAction(const RedoTextIntent(SelectionChangedCause.keyboard)),
          shortcut: _shortcut(LogicalKeyboardKey.keyZ, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          strings.cut,
          () => _textAction(
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyX),
          enabled: ready,
        ),
        _Command(
          strings.copy,
          () => _textAction(CopySelectionTextIntent.copy),
          shortcut: _shortcut(LogicalKeyboardKey.keyC),
          enabled: ready,
        ),
        _Command(
          strings.paste,
          () => _textAction(
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyV),
          enabled: ready,
        ),
        _Command(
          strings.selectAll,
          () => _textAction(
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
          shortcut: _shortcut(LogicalKeyboardKey.keyA),
          enabled: ready,
        ),
      ]),
      _ShellMenu(strings.findMenu, [
        _Command(
          strings.find,
          _find,
          shortcut: _shortcut(LogicalKeyboardKey.keyF),
          enabled: ready,
        ),
        _Command(
          strings.replace,
          () => _find(replace: true),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyF, alt: true)
              : _shortcut(LogicalKeyboardKey.keyH),
          enabled: ready,
        ),
        _Command(
          strings.findNext,
          () => active?.editor.nextMatch(),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG)
              : const SingleActivator(LogicalKeyboardKey.f3),
          enabled: ready,
        ),
        _Command(
          strings.findPrevious,
          () => active?.editor.previousMatch(),
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG, shift: true)
              : const SingleActivator(LogicalKeyboardKey.f3, shift: true),
          enabled: ready,
        ),
      ]),
      _ShellMenu(strings.window, [
        _Command(
          strings.nextTab,
          _nextTab,
          shortcut: const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
          ),
          enabled: unlocked && workspace.documents.length > 1,
        ),
        _Command(
          strings.previousTab,
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
        label: strings.appName,
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
            label: 'Quit ${strings.appName}',
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
            if (menu.label == strings.window) ...const [
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
              menu.label != strings.edit)
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
                      Text(
                        strings.appName,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                        tooltip: strings.newDocument,
                        onPressed: workspace.interactionLocked ? null : _new,
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: strings.openDocument,
                        onPressed: workspace.interactionLocked
                            ? null
                            : () => unawaited(workspace.openDialog()),
                        icon: const Icon(Icons.folder_open_outlined),
                      ),
                      IconButton(
                        tooltip: strings.save,
                        onPressed:
                            active == null ||
                                active.busy ||
                                workspace.interactionLocked
                            ? null
                            : _save,
                        icon: const Icon(Icons.save_outlined),
                      ),
                      IconButton(
                        tooltip: strings.settings,
                        onPressed: workspace.interactionLocked
                            ? null
                            : _showSettings,
                        icon: const Icon(Icons.tune),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          active?.path ?? strings.untitledHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12,
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
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Tooltip(
                                message: tab.path ?? tab.name,
                                child: Semantics(
                                  selected: tab == active,
                                  child: Material(
                                    color: tab == active
                                        ? scheme.surface
                                        : Colors.transparent,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(8),
                                    ),
                                    child: InkWell(
                                      onTap: workspace.interactionLocked
                                          ? null
                                          : () => _select(tab),
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          left: 14,
                                        ),
                                        child: Row(
                                          children: [
                                            Text(
                                              '${tab.editor.isDirty ? '● ' : ''}${tab.name}',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: tab == active
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            IconButton(
                                              key: ValueKey('close-${tab.id}'),
                                              tooltip:
                                                  '${strings.closeTabTooltip} ${tab.name}',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              iconSize: 16,
                                              onPressed:
                                                  workspace.interactionLocked ||
                                                      tab.busy
                                                  ? null
                                                  : () => unawaited(
                                                      workspace.closeTab(tab),
                                                    ),
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
                          tooltip: strings.dismissError,
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
                              strings.newDocumentTitle,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton(
                                  onPressed: _new,
                                  child: Text(strings.newDocumentAction),
                                ),
                                const SizedBox(width: 12),
                                OutlinedButton(
                                  onPressed: () =>
                                      unawaited(workspace.openDialog()),
                                  child: Text(strings.openDocumentAction),
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
                              textStyle: _textStyle,
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
    settings.removeListener(_settingsChanged);
    super.dispose();
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

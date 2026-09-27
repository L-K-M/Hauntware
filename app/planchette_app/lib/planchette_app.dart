import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
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

  /// The selected tab, so choosing one by menu or shortcut can scroll it into
  /// view. Without it, opening twenty files and switching with the Window menu
  /// leaves the tab you just chose somewhere off to the side.
  final GlobalKey _activeTabKey = GlobalKey(
    debugLabel: 'planchette.active-tab',
  );

  /// The tab last brought into view, so only a change of selection scrolls.
  DocumentTab? _revealedTab;

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    FocusManager.instance.addListener(_rememberTextFocus);
    // The tab that was already active when the window opened is at the end of
    // the strip after a session restore or a command-line open, and is just as
    // off-screen as one chosen later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelectedTab();
    });
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
    if (workspace.active != _revealedTab) {
      _revealedTab = workspace.active;
      _revealSelectedTab();
    }
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

  void _revealSelectedTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tabContext = _activeTabKey.currentContext;
      if (!mounted || tabContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          tabContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
        ),
      );
    });
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
        child: DragTarget<String>(
          onWillAcceptWithDetails: (details) => !workspace.interactionLocked,
          onAcceptWithDetails: (details) {
            for (final path in droppedPaths(details.data)) {
              unawaited(workspace.open(path));
            }
          },
          builder: (context, candidate, rejected) => _shell(
            context: context,
            menus: menus,
            tabs: tabs,
            active: active,
            scheme: scheme,
            dropping: candidate.isNotEmpty,
          ),
        ),
      ),
    );
    if (mac) body = _nativeMenu(menus, body);
    return body;
  }

  /// The window's contents.
  ///
  /// One strip holds the commands, the tabs and the document's own name, rather
  /// than a header above a tab bar. The two rows said the same thing twice — the
  /// header showed the active path and the tab below it showed the same
  /// basename — and cost about 130 pixels before the first character of the
  /// document.
  Widget _shell({
    required BuildContext context,
    required List<_ShellMenu> menus,
    required List<DocumentTab> tabs,
    required DocumentTab? active,
    required ColorScheme scheme,
    required bool dropping,
  }) => Scaffold(
    body: Stack(
      children: [
        Column(
          children: [
            if (!mac) _menuBar(menus),
            _chrome(
              tabs: tabs,
              active: active,
              scheme: scheme,
              dropping: dropping,
            ),
            Expanded(
              child: tabs.isEmpty
                  ? _emptyState(active: active, dropping: dropping)
                  : IndexedStack(
                      index: tabs.indexOf(active!),
                      children: [
                        for (final tab in tabs)
                          PlanchetteEditor(
                            key: ValueKey(tab.id),
                            controller: tab.editor,
                            isActive: tab == active,
                            editingLocked: workspace.interactionLocked,
                            indent: settings.value.indent,
                            textStyle: _textStyle,
                          ),
                      ],
                    ),
            ),
          ],
        ),
        // An error is an overlay rather than a row, so a failed save does not
        // shove the document down and then pull it back up.
        if (workspace.error case final error?)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: _ErrorBanner(
              message: error,
              onDismiss: workspace.clearError,
            ),
          ),
      ],
    ),
  );

  /// The single strip: commands, then the tabs, then the document's name.
  Widget _chrome({
    required List<DocumentTab> tabs,
    required DocumentTab? active,
    required ColorScheme scheme,
    required bool dropping,
  }) {
    final locked = workspace.interactionLocked;
    return Material(
      key: const ValueKey('planchette.chrome'),
      color: dropping ? scheme.primaryContainer : scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
        child: Row(
          children: [
            IconButton(
              tooltip: strings.newDocument,
              onPressed: locked ? null : _new,
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: strings.openDocument,
              onPressed: locked
                  ? null
                  : () => unawaited(workspace.openDialog()),
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: strings.save,
              onPressed: active == null || active.busy || locked ? null : _save,
              icon: const Icon(Icons.save_outlined),
            ),
            IconButton(
              tooltip: strings.settings,
              onPressed: locked ? null : _showSettings,
              icon: const Icon(Icons.tune),
            ),
            const SizedBox(width: 8),
            if (tabs.isEmpty)
              Expanded(
                child: Text(
                  strings.untitledHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              )
            else ...[
              Expanded(
                child: _tabStrip(tabs: tabs, active: active),
              ),
              const SizedBox(width: 12),
              // The tab already names the document; this is the directory, which
              // is the part a basename cannot carry.
              if (active?.path != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    paths.dirname(active!.path!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
            if (active?.busy == true)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }

  /// The scrolling tabs.
  Widget _tabStrip({
    required List<DocumentTab> tabs,
    required DocumentTab? active,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const ValueKey('planchette.tabs'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in tabs)
            _tab(tab: tab, selected: tab == active, scheme: scheme),
        ],
      ),
    );
  }

  /// What a tab calls its document.
  ///
  /// The basename, until two open documents share one — ten `index.js` files
  /// are otherwise ten identical tabs, and only the active tab's directory is
  /// shown beside the strip, so the strip itself has to carry the difference.
  /// Adding the parent only when it is needed keeps the common case short.
  String _tabLabel(DocumentTab tab) {
    final name = tab.name;
    final siblings = workspace.documents.where(
      (other) => other != tab && other.name == name,
    );
    if (siblings.isEmpty) return name;
    final path = tab.path;
    if (path == null) return name;
    final parent = paths.basename(paths.dirname(path));
    return parent.isEmpty || parent == '.' ? name : '$parent/$name';
  }

  Widget _tab({
    required DocumentTab tab,
    required bool selected,
    required ColorScheme scheme,
  }) {
    final locked = workspace.interactionLocked;
    final label = Text(
      _tabLabel(tab),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: tab.path ?? tab.name,
        child: Semantics(
          selected: selected,
          child: Material(
            color: selected ? scheme.surface : Colors.transparent,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: InkWell(
              key: selected ? _activeTabKey : null,
              onTap: locked ? null : () => _select(tab),
              child: Padding(
                padding: const EdgeInsets.only(left: 8, right: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // A fixed slot, so a tab does not change width the moment it
                    // becomes dirty — which it used to, twice per save.
                    SizedBox(
                      width: 10,
                      child: tab.editor.isDirty
                          ? Icon(
                              Icons.circle,
                              key: const ValueKey('planchette.dirty'),
                              size: 7,
                              color: scheme.primary,
                            )
                          : null,
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: label,
                    ),
                    IconButton(
                      key: ValueKey('close-${tab.id}'),
                      tooltip: '${strings.closeTabTooltip} ${tab.name}',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: locked || tab.busy
                          ? null
                          : () => unawaited(workspace.closeTab(tab)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState({required DocumentTab? active, required bool dropping}) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                dropping ? Icons.file_download : Icons.description_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                dropping ? 'Drop a file to open it' : strings.newDocumentTitle,
                style: theme.textTheme.titleLarge,
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
                    onPressed: () => unawaited(workspace.openDialog()),
                    child: Text(strings.openDocumentAction),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    workspace.removeListener(_changed);
    FocusManager.instance.removeListener(_rememberTextFocus);
    settings.removeListener(_settingsChanged);
    super.dispose();
  }
}

/// The paths a drop carried.
///
/// A desktop drop delivers `text/uri-list`: one `file:` URI per line, CRLF
/// separated, with comment lines beginning `//` that a file manager is free to
/// include and that mean nothing as a path. Percent escapes are decoded, and a
/// line that is already a plain path — which is what a test or a hand-made drop
/// carries — is passed through. A URI is not the same thing as a path, so
/// splitting on newlines alone produces names no file matches.
List<String> droppedPaths(String data) {
  final paths = <String>[];
  for (final line in data.split('\n')) {
    final entry = line.trim();
    if (entry.isEmpty || entry.startsWith('//')) continue;
    if (!entry.startsWith('file:')) {
      paths.add(entry);
      continue;
    }
    // A malformed URI is skipped rather than allowed to throw out of a
    // gesture handler, which would take the frame with it.
    try {
      paths.add(Uri.parse(entry).toFilePath());
    } on FormatException {
      continue;
    }
  }
  return paths;
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

/// A dismissible message over the document, rather than a row that reflows it.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4, right: 4),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss error',
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

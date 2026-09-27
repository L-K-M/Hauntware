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

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff245b5c),
      brightness: brightness,
    );
    // Planchette means a little slate, so the seed is pushed towards the
    // neutral blue-greys an editor wants behind text and the accent is
    // reserved for the things that need attention: the caret line, the dirty
    // marker, the active search match.
    final surface = scheme.surface;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: surface,
      // Stock M3 dialogs float in a lot of roundness and shadow. A text
      // editor wants a compact, flat confirmation.
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        contentTextStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      // A desktop tooltip should arrive at once and stay small.
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        textStyle: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      // A persistent thin scrollbar. A programmer scrolls a lot and the
      // default thick one arrives and disappears.
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(true),
        trackVisibility: const WidgetStatePropertyAll(false),
        thickness: const WidgetStatePropertyAll(7),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.45),
        ),
        interactive: true,
      ),
      // The stock menu bar has no baseline rule and floats; a menu bar is a
      // strip with a bottom edge.
      menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          maximumSize: const WidgetStatePropertyAll(Size(320, 480)),
        ),
      ),
    );
  }
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
    };
    Widget body = CallbackShortcuts(
      bindings: shortcuts,
      // Keep focus below the shortcuts when the final editor is disposed.
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: Column(
            // A Column centres its children across the cross axis by default,
            // which put the menu bar and the tab strip in the middle of the
            // window: both shrink-wrap their content, so both were measured
            // floating in the centre instead of sitting against the left edge
            // where every other desktop application puts them.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!mac) _menuBar(menus),
              // New, Open and Save all live in the File menu with their
              // shortcuts, the path is in the tab and the window title, and the
              // status bar already says when a save is running. A toolbar
              // repeating all of it cost 52 rows of the window to say nothing
              // that was not already one keystroke away.
              if (tabs.isNotEmpty)
                Material(
                  color: scheme.surfaceContainerHigh,
                  child: SizedBox(
                    height: _tabStripHeight,
                    // The tabs scroll rather than shrink. The behaviour below
                    // keeps a scrollbar or an overscroll glow out of the row
                    // that holds the close buttons.
                    child: ScrollConfiguration(
                      behavior: const _TabStripScroll(),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            for (final tab in tabs)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: _Tab(
                                  tab: tab,
                                  selected: tab == active,
                                  closeEnabled:
                                      !workspace.interactionLocked && !tab.busy,
                                  scheme: scheme,
                                  onSelect: () => _select(tab),
                                  onClose: () =>
                                      unawaited(workspace.closeTab(tab)),
                                ),
                              ),
                            const SizedBox(width: 8),
                          ],
                        ),
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
                    ? _EmptyState(
                        locked: workspace.interactionLocked,
                        onNew: _new,
                        onOpen: () => unawaited(workspace.openDialog()),
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

/// What the window shows before anything is open. It is the launch state, so it
/// carries the two things worth doing and the shortcut for each rather than a
/// picture on its own.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.locked,
    required this.onNew,
    required this.onOpen,
  });

  final bool locked;
  final VoidCallback onNew;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    String shortcut(LogicalKeyboardKey key) =>
        '${mac ? '⌘' : 'Ctrl+'}${key.keyLabel}';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 44,
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 18),
          Text('Start with a blank page', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Planchette edits local UTF-8 text',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: locked ? null : onNew,
                child: const Text('New document'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: locked ? null : onOpen,
                child: const Text('Open…'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          DefaultTextStyle(
            style: (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11))
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
            child: Wrap(
              spacing: 18,
              children: [
                Text('${shortcut(LogicalKeyboardKey.keyN)}  new'),
                Text('${shortcut(LogicalKeyboardKey.keyO)}  open'),
                Text('${shortcut(LogicalKeyboardKey.keyF)}  find'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Rows a tab occupies. The close button is an icon rather than a glyph, and
/// the row is fixed so a strip full of long names still lines up.
const double _tabStripHeight = 36.0;

/// One document tab.
///
/// The dirty marker is an icon rather than a bullet character so it does not
/// depend on the UI font carrying U+25CF, and the whole tab carries no
/// tooltip: a tooltip on the tab and another on its close button meant two
/// appeared at once when hovering the button.
class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.closeEnabled,
    required this.scheme,
    required this.onSelect,
    required this.onClose,
  });

  final DocumentTab tab;
  final bool selected;
  final bool closeEnabled;
  final ColorScheme scheme;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final radius = const BorderRadius.vertical(top: Radius.circular(8));
    return Tooltip(
      message: tab.path ?? tab.name,
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? scheme.surface : Colors.transparent,
          borderRadius: radius,
          // Without this the ink splash of a press paints a square over the
          // rounded top corners.
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onSelect,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tab.editor.isDirty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.circle, size: 7, color: scheme.primary),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      tab.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    key: ValueKey('close-${tab.id}'),
                    tooltip: 'Close ${tab.name}',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    iconSize: 14,
                    onPressed: closeEnabled ? onClose : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontal tab strip must not grow a scrollbar or flash an overscroll
/// glow: either eats into the row holding the close buttons, and once there
/// are more tabs than fit, the last one would be clipped by the bar. The
/// wheel and a drag already scroll it.
class _TabStripScroll extends ScrollBehavior {
  const _TabStripScroll();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
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

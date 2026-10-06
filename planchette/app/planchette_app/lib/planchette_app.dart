import 'dart:async';
import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        GhostCommandRow,
        GhostCommandSpec,
        GhostMenu,
        GhostMenuDivider,
        GhostMenuItem,
        GhostMenuRow,
        GhostSubmenuRow,
        formatShortcutActivator,
        ghostMenuBarChildren,
        ghostPlatformMenuGroups;
import 'package:planchette_editor/planchette_editor.dart'
    hide GhostMenuDivider, GhostMenuItem;

import 'services/app_settings.dart';
import 'services/document_windows.dart';
import 'services/document_workspace.dart';
import 'services/settings_dialog.dart';
import 'ui/document_windows_root.dart';
import 'theme/planchette_theme.dart';
import 'widgets/command_palette.dart';
import 'widgets/disk_notice.dart';
import 'widgets/document_status_bar.dart';
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
/// `main` resolves the stored theme here, before the window exists: passing
/// one mode to [PlanchetteApp] and another here would bring the flash
/// straight back.
Brightness effectiveBrightness(ThemeMode mode) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => PlatformDispatcher.instance.platformBrightness,
};

class PlanchetteApp extends StatelessWidget {
  const PlanchetteApp({
    super.key,
    required this.workspace,
    required this.settings,
    this.navigatorKey,
    this.window,
    this.menuSlot,
    this.onQuit,
  });

  /// This window's documents. Equals `window.workspace` when [window] is
  /// set; standalone in the single-window tests that build the app directly.
  final DocumentWorkspace workspace;

  /// The user's choices, and the only place the theme, the text size and the
  /// indentation for new documents come from.
  final SettingsController settings;

  /// The window's navigator: dialogs and prompts open in it. Null in the
  /// one-window app, where dialogs take the app's own navigator.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// The window this app is one view of; null when there is only ever one
  /// window — under `flutter test`, say, where no runner hosts views.
  final DocumentWindow? window;

  /// macOS: the app's one native menu bar, published to while this window
  /// is the active one. Null keeps the in-window `PlatformMenuBar`.
  final MenuBarSlot? menuSlot;
  final Future<void> Function()? onQuit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => MaterialApp(
      title: 'Planchette',
      navigatorKey: navigatorKey ?? window?.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: planchetteTheme(Brightness.light),
      darkTheme: planchetteTheme(Brightness.dark),
      themeMode: settings.value.themeMode,
      home: _DocumentShell(
        workspace: workspace,
        settings: settings,
        window: window,
        menuSlot: menuSlot,
        onQuit: onQuit,
      ),
    ),
  );
}

class _DocumentShell extends StatefulWidget {
  const _DocumentShell({
    required this.workspace,
    required this.settings,
    this.window,
    this.menuSlot,
    this.onQuit,
  });
  final DocumentWorkspace workspace;
  final SettingsController settings;
  final DocumentWindow? window;
  final MenuBarSlot? menuSlot;
  final Future<void> Function()? onQuit;

  @override
  State<_DocumentShell> createState() => _DocumentShellState();
}

class _DocumentShellState extends State<_DocumentShell>
    implements DocumentWindowContent {
  DocumentWorkspace get workspace => widget.workspace;
  DocumentWindow? get window => widget.window;
  bool get mac => defaultTargetPlatform == TargetPlatform.macOS;

  /// Native file drops are wired on the desktops; the mobile runners have
  /// no drop bridge, so the target stays unregistered there.
  static final bool _supportsDrop =
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  bool _dropping = false;
  FocusNode? _lastTextFocus;

  /// desktop_drop reports a drag's exit from inside the widget update that
  /// disabled the target, where setState is illegal — and a platform drag
  /// event can land mid-frame regardless — so the flag writes first and a
  /// repaint is scheduled only when no build is running.
  void _dropHover(bool hovering) {
    if (_dropping == hovering) return;
    _dropping = hovering;
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      setState(() {});
    } else {
      binding.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      // A callback added while post-frame callbacks already run only fires
      // on the next frame — request it so the repaint cannot be dropped.
      if (binding.schedulerPhase == SchedulerPhase.postFrameCallbacks) {
        binding.scheduleFrame();
      }
    }
  }

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

  SettingsController get settings => widget.settings;

  int get _fontSize => settings.value.fontSize;

  /// View › Zoom steps through the sizes every Ghost editor shares.
  void _zoom(EditorZoom zoom) =>
      _setFontSize(EditorTextSize.zoomed(_fontSize, zoom));

  /// Zoom is a setting: it applies to every tab and outlasts the session.
  void _setFontSize(int size) =>
      unawaited(settings.update(settings.value.copyWith(fontSize: size)));

  bool _settingsOpen = false;

  /// The native macOS menu stays live under the dialog, so a second request
  /// is ignored, as the palette does; a second dialog on top would make the
  /// first one's Cancel restore the previewed values.
  Future<void> _showSettings() async {
    if (_settingsOpen || workspace.interactionLocked) return;
    _settingsOpen = true;
    try {
      await SettingsDialog.show(context, settings: settings);
    } finally {
      _settingsOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    workspace.addListener(_changed);
    settings.addListener(_settingsChanged);
    workspace.toolHistory.addListener(_toolHistoryChanged);
    window?.attachContent(this);
    // Activation and the window list are the window registry's news, not
    // this workspace's: which shell publishes the macOS menu and which
    // window rows the Window menu lists both follow it.
    window?.owner.addListener(_changed);
    _applySettings();
    FocusManager.instance.addListener(_rememberTextFocus);
  }

  /// The window came forward remembering nothing (its first activation):
  /// focus goes to the document it is showing.
  @override
  void claimDefaultFocus() => workspace.active?.editor.restoreFocus();

  @override
  void didUpdateWidget(_DocumentShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != settings) {
      oldWidget.settings.removeListener(_settingsChanged);
      settings.addListener(_settingsChanged);
      _settingsChanged();
    }
  }

  /// Push user choices into the workspace: indentation for new documents
  /// and save normalization for current and later editors.
  void _applySettings() {
    final value = settings.value;
    workspace.indentationPreference = value.indentation;
    workspace.saveOptions = value.saveOptions;
  }

  void _settingsChanged() {
    _applySettings();
    if (mounted) setState(() {});
  }

  /// A recorded run changes the Repeat and Recent labels, and the
  /// persistable part of the history is a setting — saved through the
  /// same debounced write as the rest.
  void _toolHistoryChanged() {
    unawaited(
      settings.update(
        settings.value.copyWith(
          recentTextTools: workspace.toolHistory.encode(),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _rememberTextFocus() {
    final focus = FocusManager.instance.primaryFocus;
    final tab = workspace.active;
    if (tab == null ||
        !tab.editor.textFocusNodes.contains(focus) ||
        focus == _lastTextFocus) {
      return;
    }
    final wasDocument = _documentInUse;
    _lastTextFocus = focus;
    // The menus offer document commands only while the document is in use.
    if (_documentInUse != wasDocument) setState(() {});
  }

  /// Whether the text field in use is the document rather than a find or
  /// Go to Line field. Commands that only edit the document, and their
  /// shortcuts, are offered only then: a key those fields leave unhandled,
  /// or the native menu's key equivalent, must not edit the hidden text.
  bool get _documentInUse {
    final tab = workspace.active;
    if (tab == null) return false;
    final remembered = _lastTextFocus;
    return remembered == null ||
        remembered == tab.editor.editorFocus ||
        !tab.editor.textFocusNodes.contains(remembered);
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
  void _revert() {
    final tab = workspace.active;
    if (tab != null) unawaited(workspace.revert(tab));
  }

  /// Exports in the colors the editor is showing: its syntax theme and the
  /// page behind it.
  void _exportHtml() {
    final tab = workspace.active;
    if (tab == null) return;
    String css(Color color) =>
        '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final scheme = Theme.of(context).colorScheme;
    final syntax = tab.editor.text.theme;
    unawaited(
      workspace.exportHtml(
        tab,
        HtmlPalette(
          background: css(scheme.surface),
          foreground: css(scheme.onSurface),
          tokens: {
            for (final type in SyntaxTokenType.values)
              type: css(syntax.colorFor(type)),
          },
        ),
      ),
    );
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
      // Under a dialog such as the command palette, the editor focuses
      // itself once the dialog is gone rather than taking the dialog's.
      if (mounted &&
          workspace.active == tab &&
          !workspace.interactionLocked &&
          (ModalRoute.isCurrentOf(context) ?? true)) {
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

  /// The tooltip spelling of a base chord with [key]: `⌘N`/`Ctrl+N`.
  String _keyLabel(LogicalKeyboardKey key) =>
      formatShortcutActivator(
        _shortcut(key),
        mac ? TargetPlatform.macOS : TargetPlatform.linux,
      ) ??
      key.keyLabel;

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
        GhostMenuItem<void>(
          context: context,
          label: 'Close',
          icon: Icons.close,
          enabled: !workspace.interactionLocked && !tab.busy,
          onTap: () => unawaited(workspace.closeTab(tab)),
        ),
        GhostMenuItem<void>(
          context: context,
          label: 'Close Others',
          icon: Icons.tab_unselected,
          enabled: hasOthers && !workspace.interactionLocked,
          onTap: () => unawaited(workspace.closeOthers(tab)),
        ),
        GhostMenuItem<void>(
          context: context,
          label: 'Close All Tabs',
          icon: Icons.clear_all,
          enabled: !workspace.interactionLocked,
          onTap: () => unawaited(workspace.closeAllTabs()),
        ),
        const GhostMenuDivider(),
        // From #66.
        GhostMenuItem<void>(
          context: context,
          label: 'Copy Full Path',
          icon: Icons.copy,
          enabled: tab.path != null,
          onTap: () => _copyPath(tab.path),
        ),
      ],
    );
  }

  /// Copies a file path to the clipboard. Shared by the tab context menu
  /// and File › Copy Path, so both copy the same text.
  void _copyPath(String? path) {
    if (path case final value?) {
      unawaited(Clipboard.setData(ClipboardData(text: value)));
    }
  }

  void _copyActivePath() => _copyPath(workspace.active?.path);

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

  bool _paletteOpen = false;

  /// The editor's display strings, for Text-menu tool names.
  static const _editorStrings = EditorStrings();

  /// Lists every command the menus define, enabled or not — a greyed row
  /// still answers "where does that live". The native macOS menu stays
  /// live under the palette, so a second request is ignored.
  Future<void> _openPalette() async {
    if (_paletteOpen || workspace.interactionLocked) return;
    final commands = <PaletteCommand>[];
    // A command can appear in two menus (a catalog id next to an explicit
    // one); the palette keeps the first, the resolution _commandById does.
    final seenIds = <String>{};
    void collect(List<_MenuEntry> items, String path) {
      for (final entry in items) {
        switch (entry) {
          case _Submenu(:final items, :final label):
            collect(items, '$path > $label');
          case _Command() when entry.run != _openPalette && entry.inPalette:
            final tool = entry.id == null ? null : textToolById(entry.id!);
            final id = _paletteId(entry, path);
            if (!seenIds.add(id)) continue;
            commands.add(
              PaletteCommand(
                id: id,
                label: entry.label,
                path: path,
                description: tool == null
                    ? ''
                    : _editorStrings.textToolDescription(tool.id),
                keywords: tool == null
                    ? const []
                    : _editorStrings.textToolKeywords(tool.id),
                enabled: entry.enabled,
                run: () => _runCurrent(_paletteId(entry, path)),
                shortcut: entry.shortcut,
              ),
            );
          case _Command() || _Separator():
        }
      }
    }

    for (final menu in _menus()) {
      collect(menu.items, menu.label);
    }
    _paletteOpen = true;
    try {
      await showCommandPalette(context, commands);
    } finally {
      _paletteOpen = false;
    }
  }

  /// What identifies a command to the palette: the explicit id when the
  /// command declares one, else its menu path — two same-named commands
  /// in different menus would otherwise collide on their label.
  static String _paletteId(_Command command, String path) =>
      command.id ?? '$path > ${command.label}';

  /// The menu's command for [commandId], descending into submenus.
  _Command? _commandById(String commandId) {
    _Command? find(List<_MenuEntry> items, String path) {
      for (final entry in items) {
        switch (entry) {
          case _Submenu(:final items, :final label):
            final found = find(items, '$path > $label');
            if (found != null) return found;
          case _Command() when _paletteId(entry, path) == commandId:
            return entry;
          case _Command() || _Separator():
        }
      }
      return null;
    }

    for (final menu in _menus()) {
      final found = find(menu.items, menu.label);
      if (found != null) return found;
    }
    return null;
  }

  /// Runs a command the palette offered as the menus define it now: the
  /// native menu stays live under the palette, so the active tab, or whether
  /// the command still applies, may have changed since it opened.
  void _runCurrent(String commandId) {
    if (!mounted) return;
    final command = _commandById(commandId);
    if (command != null && command.enabled) command.run();
  }

  /// A no-options tool runs straight away; a tool that declares options
  /// opens the bar so the user sets them first. A find-bar tool opens find
  /// instead: its options are the query and the toggles.
  void _runOrOpenTextTool(TextTool tool) {
    final editor = workspace.active?.editor;
    if (editor == null) return;
    if (tool.usesFindBar) {
      editor.openFindTool(tool.id);
    } else if (tool.options.isEmpty) {
      unawaited(editor.runTextTool(tool.id));
    } else {
      editor.openTextTool(tool.id);
    }
  }

  /// Repeat runs the last tool with the options it last used — bar and
  /// menu runs both record, so the label's summary is what re-runs.
  void _repeatTextTool() {
    final editor = workspace.active?.editor;
    if (editor == null) return;
    unawaited(editor.repeatTextTool());
  }

  void _runRecentTextTool(TextToolRunRecord? record) {
    final editor = workspace.active?.editor;
    if (record == null || editor == null) return;
    unawaited(editor.runRecentTextTool(record));
  }

  void _find({bool replace = false}) {
    if (!workspace.interactionLocked) {
      workspace.active?.editor.openSearch(replace: replace);
    }
  }

  /// Compare with Saved runs on the saved file the active tab holds, so the
  /// command waits for one; untitled tabs keep the row, greyed.
  void _compareWithSaved() {
    final tab = workspace.active;
    if (tab != null) unawaited(workspace.compareWithSaved(tab));
  }

  SingleActivator _shortcut(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) => SingleActivator(key, meta: mac, control: !mac, shift: shift, alt: alt);

  /// A View › Zoom row. Its first chord shows in the menu; the rest cover
  /// where `+` and `-` sit across layouts and on the keypad.
  _Command _zoomCommand(
    String label,
    EditorZoom zoom, {
    required String mnemonic,
  }) {
    final chords = EditorTextSize.activators(zoom, defaultTargetPlatform);
    return _Command(
      label,
      () => _zoom(zoom),
      mnemonic: mnemonic,
      shortcut: chords.first,
      aliases: chords.skip(1).toList(),
      enabled: EditorTextSize.canZoom(_fontSize, zoom),
    );
  }

  List<_ShellMenu> _menus() {
    final active = workspace.active;
    final unlocked = !workspace.interactionLocked;
    final ready = _documentReady;
    // The tab's × is available whenever no save is in flight and the
    // workspace isn't interaction-locked — including during load or after
    // a load error — so the menu command follows the same rule.
    final closable = active != null && unlocked && !active.busy;
    // A composing input method or a host lock refuses line edits too.
    final inDocument = ready && _documentInUse;
    final lineCommands = inDocument && (active?.editor.canEditText ?? false);
    // Selection moves nothing, so a locked document allows it.
    final selectionCommands =
        inDocument && (active?.editor.canMoveCaret ?? false);
    final hasSelection = inDocument && (active?.editor.hasSelection ?? false);
    final hasProblems =
        ready &&
        (active?.editor.canRunCommand(EditorCommand.nextProblem) ?? false);
    return [
      _ShellMenu('File', [
        _Command(
          'New',
          _new,
          mnemonic: 'n',
          shortcut: _shortcut(LogicalKeyboardKey.keyN),
          enabled: unlocked,
        ),
        // One window per workspace; greyed where the runner cannot host
        // more than the one it launched with.
        if (window case final w?)
          _Command(
            'New Window',
            () => unawaited(w.openWindow()),
            mnemonic: 'w',
            shortcut: _shortcut(LogicalKeyboardKey.keyN, shift: true),
            enabled: w.canOpenWindows,
          ),
        _Command(
          'Open…',
          () => unawaited(workspace.openDialog()),
          mnemonic: 'o',
          shortcut: _shortcut(LogicalKeyboardKey.keyO),
          enabled: unlocked,
        ),
        const _Separator(),
        _Command(
          'Save',
          _save,
          mnemonic: 's',
          shortcut: _shortcut(LogicalKeyboardKey.keyS),
          enabled: ready,
        ),
        _Command(
          'Save As…',
          () => _save(saveAs: true),
          mnemonic: 'a',
          shortcut: _shortcut(LogicalKeyboardKey.keyS, shift: true),
          enabled: ready,
        ),
        _Command(
          'Save All',
          _saveAll,
          // Menu-only off macOS: Windows reports AltGr as Ctrl+Alt, so
          // Ctrl+Alt+S would swallow text such as Polish AltGr+S.
          mnemonic: 'l',
          shortcut: mac ? _shortcut(LogicalKeyboardKey.keyS, alt: true) : null,
          enabled:
              unlocked && workspace.documents.any((tab) => tab.editor.isDirty),
        ),
        // No shortcut: no platform convention names one, Cmd+R and Ctrl+R
        // mean other things elsewhere, and a revert cannot be undone.
        _Command(
          'Revert to Saved',
          _revert,
          // A deleted file has no saved version to go back to.
          mnemonic: 'r',
          enabled:
              ready &&
              active?.path != null &&
              active?.disk != DiskState.missing,
        ),
        _Command('Export as HTML…', _exportHtml, mnemonic: 'x', enabled: ready),
        _Command(
          'Copy Path',
          _copyActivePath,
          mnemonic: 'p',
          enabled: active?.path != null,
          id: 'copyPath',
        ),
        const _Separator(),
        // macOS keeps Settings in the application menu instead.
        if (!mac)
          _Command(
            'Settings…',
            _showSettings,
            mnemonic: 'e',
            shortcut: _shortcut(LogicalKeyboardKey.comma),
            enabled: !workspace.interactionLocked,
          ),
        _Command(
          'Close Tab',
          _close,
          mnemonic: 'c',
          shortcut: _shortcut(LogicalKeyboardKey.keyW),
          enabled: closable,
        ),
        // The window's own close: the same dirty guard its close button
        // runs, and the last window quits the app.
        if (window case final w?)
          _Command(
            'Close Window',
            () => unawaited(w.close()),
            shortcut: _shortcut(LogicalKeyboardKey.keyW, shift: true),
          ),
        _Command(
          'Reopen Closed Tab',
          () => unawaited(workspace.reopenClosed()),
          mnemonic: 't',
          shortcut: _shortcut(LogicalKeyboardKey.keyT, shift: true),
          enabled: workspace.canReopenClosed,
        ),
        if (!mac && widget.onQuit != null) ...[
          const _Separator(),
          _Command(
            'Quit',
            () => unawaited(widget.onQuit!()),
            mnemonic: 'q',
            shortcut: _shortcut(LogicalKeyboardKey.keyQ),
            enabled: unlocked,
          ),
        ],
      ], mnemonic: 'f'),
      _ShellMenu('Edit', [
        _Command(
          'Undo',
          () =>
              _textAction(const UndoTextIntent(SelectionChangedCause.keyboard)),
          mnemonic: 'u',
          shortcut: _shortcut(LogicalKeyboardKey.keyZ),
          enabled: ready,
        ),
        _Command(
          'Redo',
          () =>
              _textAction(const RedoTextIntent(SelectionChangedCause.keyboard)),
          mnemonic: 'r',
          shortcut: _shortcut(LogicalKeyboardKey.keyZ, shift: true),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          'Cut',
          () => _textAction(
            const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
          ),
          mnemonic: 't',
          shortcut: _shortcut(LogicalKeyboardKey.keyX),
          enabled: ready,
        ),
        _Command(
          'Copy',
          () => _textAction(CopySelectionTextIntent.copy),
          mnemonic: 'c',
          shortcut: _shortcut(LogicalKeyboardKey.keyC),
          enabled: ready,
        ),
        _Command(
          'Paste',
          () => _textAction(
            const PasteTextIntent(SelectionChangedCause.keyboard),
          ),
          mnemonic: 'p',
          shortcut: _shortcut(LogicalKeyboardKey.keyV),
          enabled: ready,
        ),
        _Command(
          'Select All',
          () => _textAction(
            const SelectAllTextIntent(SelectionChangedCause.keyboard),
          ),
          mnemonic: 'a',
          shortcut: _shortcut(LogicalKeyboardKey.keyA),
          enabled: ready,
        ),
        const _Separator(),
        _Command(
          'Duplicate Line',
          () => active?.editor.duplicateLines(),
          mnemonic: 'd',
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
          mnemonic: 'l',
          shortcut: _shortcut(LogicalKeyboardKey.keyK, shift: true),
          enabled: lineCommands,
        ),
        _Command(
          'Join Lines',
          () => active?.editor.joinLines(),
          mnemonic: 'j',
          shortcut: _shortcut(LogicalKeyboardKey.keyJ),
          enabled: lineCommands,
        ),
        const _Separator(),
        _Command(
          'Toggle Comment',
          () => active?.editor.toggleComment(),
          shortcut: _shortcut(LogicalKeyboardKey.slash),
          enabled: inDocument && (active?.editor.canToggleComment ?? false),
        ),
        // No chords for this group: the existing Edit shortcuts already
        // cover the field's bindings, and new chords are unchecked against
        // desktop environments and input methods.
        const _Separator(),
        _Command(
          'Select Line',
          () => active?.editor.selectLine(),
          mnemonic: 's',
          enabled: selectionCommands,
          id: 'selectLine',
        ),
        _Command(
          'Select Paragraph',
          () => active?.editor.selectParagraph(),
          enabled: selectionCommands,
          id: 'selectParagraph',
        ),
        _Command(
          'Select Enclosing Brackets',
          () => active?.editor.selectEnclosingBrackets(),
          enabled: selectionCommands,
          id: 'selectEnclosingBrackets',
        ),
        const _Separator(),
        _Command(
          'Insert Line Above',
          () => active?.editor.insertLineAbove(),
          mnemonic: 'v',
          enabled: lineCommands,
          id: 'insertLineAbove',
        ),
        _Command(
          'Insert Line Below',
          () => active?.editor.insertLineBelow(),
          mnemonic: 'b',
          enabled: lineCommands,
          id: 'insertLineBelow',
        ),
        _Command(
          'Copy Line',
          () {
            final editor = active?.editor;
            if (editor != null) unawaited(editor.copyLine().then<void>((_) {}));
          },
          enabled: selectionCommands,
          id: 'copyLine',
        ),
        _Command(
          'Cut Line',
          () {
            final editor = active?.editor;
            if (editor != null) unawaited(editor.cutLine().then<void>((_) {}));
          },
          enabled: lineCommands,
          id: 'cutLine',
        ),
        _Command(
          'Increment Number',
          () => active?.editor.incrementNumber(),
          enabled: lineCommands,
          id: 'incrementNumber',
        ),
        _Command(
          'Decrement Number',
          () => active?.editor.decrementNumber(),
          enabled: lineCommands,
          id: 'decrementNumber',
        ),
        _Command(
          'Paste and Match Indentation',
          () {
            final editor = active?.editor;
            if (editor != null) {
              unawaited(editor.pasteAndMatchIndentation().then<void>((_) {}));
            }
          },
          enabled: lineCommands,
          id: 'pasteMatchIndentation',
        ),
      ], mnemonic: 'e'),
      // The catalog drives the menu: Repeat and Recent head it, then one
      // submenu per group that has at least one built tool — a group not
      // yet built is absent rather than empty. A tool that declares
      // options opens the tool bar instead of running at its defaults.
      _ShellMenu('Text', [
        _Command(
          _editorStrings.repeatTextToolLabel(workspace.toolHistory.last),
          _repeatTextTool,
          mnemonic: 'r',
          shortcut: _shortcut(LogicalKeyboardKey.keyR, shift: true),
          enabled: lineCommands && workspace.toolHistory.last != null,
          id: 'repeatTextTool',
        ),
        _Submenu('Recent', [
          if (workspace.toolHistory.recent.isEmpty)
            const _Command(
              'No Recent Runs',
              _noop,
              enabled: false,
              inPalette: false,
            )
          else
            for (final (index, record) in workspace.toolHistory.recent.indexed)
              _Command(
                _editorStrings.recentTextToolLabel(record),
                () => _runRecentTextTool(record),
                enabled: lineCommands,
                id: 'recentTextTool:$index',
              ),
        ], mnemonic: 'e'),
        const _Separator(),
        // The browser is the phone and header-icon entry to the same
        // catalog the submenus below list; the menus stay primary.
        _Command(
          _editorStrings.browseTextTools,
          () => active?.editor.openTextTools(),
          mnemonic: 'b',
          enabled: ready,
          id: 'browseTextTools',
        ),
        for (final group in TextToolGroup.values)
          if (textToolCatalog.any(
            (tool) => tool.group == group && tool.showsInMenu,
          ))
            _Submenu(_editorStrings.textToolGroupName(group), [
              for (final tool in textToolCatalog)
                if (tool.group == group && tool.showsInMenu)
                  _Command(
                    _editorStrings.textToolMenuLabel(tool.id),
                    () => _runOrOpenTextTool(tool),
                    enabled: lineCommands,
                    id: tool.id,
                  ),
            ]),
      ], mnemonic: 't'),
      _ShellMenu('Find', [
        _Command(
          'Find…',
          _find,
          mnemonic: 'f',
          shortcut: _shortcut(LogicalKeyboardKey.keyF),
          enabled: ready,
        ),
        _Command(
          'Replace…',
          () => _find(replace: true),
          mnemonic: 'r',
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyF, alt: true)
              : _shortcut(LogicalKeyboardKey.keyH),
          enabled: ready,
        ),
        _Command(
          'Find Next',
          () => active?.editor.nextMatch(),
          mnemonic: 'n',
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG)
              : const SingleActivator(LogicalKeyboardKey.f3),
          enabled: ready,
        ),
        _Command(
          'Find Previous',
          () => active?.editor.previousMatch(),
          mnemonic: 'p',
          shortcut: mac
              ? _shortcut(LogicalKeyboardKey.keyG, shift: true)
              : const SingleActivator(LogicalKeyboardKey.f3, shift: true),
          enabled: ready,
        ),
        _Command(
          _editorStrings.findInSelection,
          () => active?.editor.findInSelection(),
          mnemonic: 's',
          enabled: hasSelection,
        ),
        _Command(
          _editorStrings.textToolMenuLabel('extractMatches'),
          () => active?.editor.openFindTool('extractMatches'),
          mnemonic: 'x',
          enabled: lineCommands,
          id: 'extractMatches',
        ),
        const _Separator(),
        _Command(
          'Go to Matching Bracket',
          () => active?.editor.goToMatchingBracket(),
          mnemonic: 'g',
          shortcut: _shortcut(LogicalKeyboardKey.keyB),
          enabled: inDocument,
        ),
        _Command(
          'Select to Matching Bracket',
          () => active?.editor.goToMatchingBracket(extend: true),
          mnemonic: 't',
          shortcut: _shortcut(LogicalKeyboardKey.keyB, shift: true),
          enabled: inDocument,
        ),
        const _Separator(),
        _Command(
          'Go to Line…',
          () => workspace.active?.editor.openGoToLine(),
          mnemonic: 'l',
          shortcut: _shortcut(
            mac ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.keyG,
          ),
          enabled: ready,
        ),
        // F8 on every platform, as in the common code editors; the editor
        // binds the same keys for hosts without menus.
        _Command(
          'Next Problem',
          () => active?.editor.nextProblem(),
          mnemonic: 'o',
          shortcut: const SingleActivator(LogicalKeyboardKey.f8),
          enabled: hasProblems,
        ),
        _Command(
          'Previous Problem',
          () => active?.editor.previousProblem(),
          mnemonic: 'v',
          shortcut: const SingleActivator(LogicalKeyboardKey.f8, shift: true),
          enabled: hasProblems,
        ),
        const _Separator(),
        _Command(
          'Compare with Saved',
          _compareWithSaved,
          // A deleted file has no saved version on disk to compare with,
          // the same rule Revert to Saved follows.
          mnemonic: 'c',
          enabled:
              ready &&
              active?.path != null &&
              active?.disk != DiskState.missing,
          id: 'compareWithSaved',
        ),
      ], mnemonic: 'n'),
      _ShellMenu('View', [
        _zoomCommand('Zoom In', EditorZoom.zoomIn, mnemonic: 'i'),
        _zoomCommand('Zoom Out', EditorZoom.zoomOut, mnemonic: 'o'),
        _zoomCommand('Actual Size', EditorZoom.actualSize, mnemonic: 'a'),
      ], mnemonic: 'v'),
      _ShellMenu('Window', [
        _Command(
          'Command Palette…',
          _openPalette,
          mnemonic: 'c',
          shortcut: _shortcut(LogicalKeyboardKey.keyP, shift: true),
          enabled: unlocked,
        ),
        const _Separator(),
        _Command(
          'Next Tab',
          _nextTab,
          mnemonic: 'n',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
          ),
          enabled: unlocked && workspace.documents.length > 1,
        ),
        _Command(
          'Previous Tab',
          () => _nextTab(previous: true),
          mnemonic: 'p',
          shortcut: const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
            shift: true,
          ),
          enabled: unlocked && workspace.documents.length > 1,
        ),
        // The app's windows, front-marked: choosing one raises it.
        if (window case final w?) ...[
          const _Separator(),
          for (final other in w.owner.windows)
            _Command(
              '${other.isActive ? '✓ ' : ''}${other.workspace.windowTitle}',
              () => unawaited(other.activate()),
              enabled: true,
              inPalette: false,
            ),
        ],
      ], mnemonic: 'w'),
    ];
  }

  /// The shared snapshot for one command: the primary shortcut first so
  /// hint and native key equivalent spell it, the aliases after.
  GhostCommandSpec _commandSpec(_Command command) => GhostCommandSpec(
    id: command.id,
    label: command.label,
    enabled: command.enabled,
    mnemonic: command.mnemonic,
    activators: [?command.shortcut, ...command.aliases],
    onSelected: command.run,
  );

  /// One menu's entries as shared model groups, split at separators.
  /// A submenu's items are commands only — menus never nest deeper.
  List<List<GhostMenuRow>> _menuGroups(List<_MenuEntry> entries) {
    final groups = <List<GhostMenuRow>>[];
    var group = <GhostMenuRow>[];
    void flush() {
      if (group.isEmpty) return;
      groups.add(group);
      group = [];
    }

    for (final entry in entries) {
      switch (entry) {
        case _Separator():
          flush();
        case _Submenu():
          // A submenu is one item to its parent; it shares the current
          // group so adjacent submenus are not separated by dividers.
          // The shared model's submenu items are leaf rows only — a
          // separator or nested menu inside one would drop silently.
          assert(
            entry.items.every((item) => item is _Command),
            'Submenu "${entry.label}" carries non-command entries the '
            'shared menu model cannot render',
          );
          group.add(
            GhostSubmenuRow(
              title: entry.label,
              mnemonic: entry.mnemonic,
              items: [
                for (final item in entry.items)
                  if (item case final _Command command)
                    GhostCommandRow(_commandSpec(command)),
              ],
            ),
          );
        case _Command():
          group.add(GhostCommandRow(_commandSpec(entry)));
      }
    }
    flush();
    return groups;
  }

  /// The menu as the shared model sees it, for both renderers.
  GhostMenu _ghostMenu(_ShellMenu menu) => GhostMenu(
    title: menu.label,
    mnemonic: menu.mnemonic,
    groups: _menuGroups(menu.items),
  );

  List<PlatformMenuItem> _nativeItems(List<_MenuEntry> entries) =>
      ghostPlatformMenuGroups(_menuGroups(entries));

  /// The full native menu tree this window would show — the application
  /// menu plus every top-level menu. With several windows the root renders
  /// the single bar these are published into; in the one-window app they go
  /// to this window's own `PlatformMenuBar`.
  List<PlatformMenuItem> _nativeMenus(List<_ShellMenu> menus) => [
    PlatformMenu(
      label: 'Planchette',
      menus: [
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.about,
        ),
        // Settings belong in the application menu on macOS.
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Settings…',
              shortcut: _shortcut(LogicalKeyboardKey.comma),
              onSelected: workspace.interactionLocked ? null : _showSettings,
            ),
          ],
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
  ];

  Widget _nativeMenu(List<_ShellMenu> menus, Widget child) =>
      PlatformMenuBar(menus: _nativeMenus(menus), child: child);

  /// The latest native menu tree this build made: the post-frame publish
  /// checks identity so a newer build's items win over a stale callback.
  List<PlatformMenuItem>? _latestNativeMenus;

  /// Hands this window's menus to the root's one menu bar after the frame
  /// (a slot change rebuilds the root, which must not happen mid-build).
  /// Only the active window publishes, and only its newest items land.
  void _publishMenu(MenuBarSlot slot, List<PlatformMenuItem> menus) {
    _latestNativeMenus = menus;
    final window = this.window;
    if (window == null || !window.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !window.isActive) return;
      if (!identical(_latestNativeMenus, menus)) return;
      slot.publish(window, menus);
    });
  }

  Widget _menuBar(List<_ShellMenu> menus) => MenuBar(
    style: MenuStyle(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(
        Theme.of(context).colorScheme.surface,
      ),
    ),
    children: ghostMenuBarChildren([
      for (final menu in menus) _ghostMenu(menu),
    ], divider: const Divider(height: 8)),
  );

  @override
  Widget build(BuildContext context) {
    final menus = _menus();
    final tabs = workspace.documents;
    final active = workspace.active;
    final scheme = Theme.of(context).colorScheme;
    final shortcuts = <ShortcutActivator, VoidCallback>{};
    void bindShortcuts(List<_MenuEntry> items) {
      for (final entry in items) {
        switch (entry) {
          case _Submenu(:final items):
            bindShortcuts(items);
          case _Command() when entry.shortcut != null:
            for (final shortcut in [entry.shortcut!, ...entry.aliases]) {
              shortcuts[shortcut] = () {
                if (entry.enabled) entry.run();
              };
            }
          case _Command() || _Separator():
        }
      }
    }

    for (final menu in menus) {
      // The field owns Edit's chords, so they are not bound here.
      if (menu.label != 'Edit') bindShortcuts(menu.items);
    }
    for (var number = 1; number <= 9; number++) {
      shortcuts[_shortcut(_digits[number])] = () => _selectNumbered(number);
    }
    Widget body = CallbackShortcuts(
      bindings: shortcuts,
      // Keep focus below the shortcuts when the final editor is disposed.
      child: FocusScope(
        autofocus: true,
        child: DropTarget(
          // While a dialog or quit review owns the workspace the file must
          // not sneak in behind it, so the target unregisters outright.
          enable: _supportsDrop && !workspace.interactionLocked,
          onDragEntered: (_) => _dropHover(true),
          onDragExited: (_) => _dropHover(false),
          onDragDone: (details) {
            _dropHover(false);
            final paths = [for (final item in details.files) item.path];
            if (paths.isEmpty) return;
            final registry = window?.owner;
            unawaited(
              registry != null
                  ? registry.openDocuments(paths)
                  : workspace.openAll(paths),
            );
          },
          child: DecoratedBox(
            key: const ValueKey('window-drop-highlight'),
            // The border sits over the shell — as a background decoration the
            // Scaffold's opaque Material would cover it. Disabling the target
            // makes desktop_drop report the drag's exit during the update, so
            // the flag is already false before a locked frame ever paints.
            position: DecorationPosition.foreground,
            decoration: _dropping
                ? BoxDecoration(
                    border: Border.all(color: scheme.primary, width: 2),
                  )
                : const BoxDecoration(),
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
                    onSelect: (id) =>
                        _select(tabs.firstWhere((t) => t.id == id)),
                    onClose: (id) => unawaited(
                      workspace.closeTab(tabs.firstWhere((t) => t.id == id)),
                    ),
                    onContextMenu: (id, position) => _showTabMenu(
                      position,
                      tabs.firstWhere((t) => t.id == id),
                    ),
                    onNew: _new,
                    onOpen: () => unawaited(workspace.openDialog()),
                    onSave: _documentReady ? _save : null,
                    newTooltip: 'New (${_keyLabel(LogicalKeyboardKey.keyN)})',
                    openTooltip:
                        'Open… (${_keyLabel(LogicalKeyboardKey.keyO)})',
                    saveTooltip: 'Save (${_keyLabel(LogicalKeyboardKey.keyS)})',
                  ),
                  if (workspace.error case final error?)
                    _errorBanner(
                      key: const ValueKey('workspace-error-banner'),
                      message: error,
                      onDismiss: workspace.clearError,
                    ),
                  if (settings.error case final error?)
                    _errorBanner(
                      key: const ValueKey('settings-error-banner'),
                      message: error,
                      onDismiss: settings.clearError,
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
                                    // Offered only when they would act, like the
                                    // strip's buttons (from #36).
                                    FilledButton(
                                      onPressed: workspace.interactionLocked
                                          ? null
                                          : _new,
                                      child: const Text('New document'),
                                    ),
                                    const SizedBox(width: 12),
                                    OutlinedButton(
                                      onPressed: workspace.interactionLocked
                                          ? null
                                          : () => unawaited(
                                              workspace.openDialog(),
                                            ),
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
                                  // Only what the user chose: the editor supplies
                                  // the platform's monospace stack and the line
                                  // height beneath it.
                                  textStyle: TextStyle(
                                    fontFamily: settings.value.fontFamily,
                                    fontSize: _fontSize.toDouble(),
                                  ),
                                  controller: tab.editor,
                                  isActive: tab == active,
                                  banner: _diskNotice(tab),
                                  // App-only clickable status; the shared
                                  // editor keeps its passive default.
                                  statusBuilder: (context, controller) =>
                                      DocumentStatusBar(controller: controller),
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
        ),
      ),
    );
    if (mac) {
      final slot = widget.menuSlot;
      if (slot != null && window != null) {
        // The root renders the one native menu bar; this window's items go
        // there while it is the active one.
        _publishMenu(slot, _nativeMenus(menus));
      } else {
        body = _nativeMenu(menus, body);
      }
    }
    return body;
  }

  /// Tabs without edits take an outside change silently; everything else
  /// the disk check found is explained here.
  Widget? _diskNotice(DocumentTab tab) {
    if (tab.disk == DiskState.current) return null;
    return DiskNotice(
      key: ValueKey('disk-notice-${tab.id}'),
      state: tab.disk,
      name: tab.name,
      // A reload in flight would replace the text after Keep Mine.
      enabled: !workspace.interactionLocked && !tab.busy && !tab.editor.isBusy,
      onReload: () => unawaited(workspace.reloadFromDisk(tab)),
      onKeepMine: tab.editor.isDirty ? () => workspace.keepMine(tab) : null,
      onSave: () => unawaited(workspace.save(tab)),
    );
  }

  Widget _errorBanner({
    required Key key,
    required String message,
    required VoidCallback onDismiss,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: key,
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              IconButton(
                tooltip: 'Dismiss error',
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    workspace.removeListener(_changed);
    settings.removeListener(_settingsChanged);
    workspace.toolHistory.removeListener(_toolHistoryChanged);
    // A closing window retracts only its own menu; the next active one
    // publishes its own after this frame.
    final window = this.window;
    // Detaching notifies the owner; the listener has to go first or the
    // notification reaches a defunct State.
    window?.owner.removeListener(_changed);
    window?.detachContent(this);
    if (window != null) widget.menuSlot?.clear(window);
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
  const _ShellMenu(this.label, this.items, {this.mnemonic});
  final String label;
  final List<_MenuEntry> items;

  /// The Alt-access letter on the in-window menu bar, Windows and Linux
  /// only. Null leaves the label unmarked; the native macOS menu and the
  /// palette never see it.
  final String? mnemonic;
}

sealed class _MenuEntry {
  const _MenuEntry();
}

final class _Separator extends _MenuEntry {
  const _Separator();
}

/// A labelled group of entries nested one level under its menu. Menus
/// never go deeper: Apple's and Windows' guidance both stop at one level
/// of submenus.
final class _Submenu extends _MenuEntry {
  const _Submenu(this.label, this.items, {this.mnemonic});
  final String label;
  final List<_MenuEntry> items;

  /// The Alt-access letter on the in-window menu bar, Windows and Linux
  /// only. Null leaves the label unmarked.
  final String? mnemonic;
}

final class _Command extends _MenuEntry {
  const _Command(
    this.label,
    this.run, {
    this.shortcut,
    this.aliases = const [],
    this.enabled = true,
    this.id,
    this.inPalette = true,
    this.mnemonic,
  });

  /// The stable identifier the palette resolves the command by, so a row
  /// whose label changes — Repeat names its target — still resolves.
  /// Commands without one are identified by their menu path.
  final String? id;
  final String label;
  final VoidCallback run;
  final SingleActivator? shortcut;

  /// More key combinations for the same command, not shown in menus.
  final List<SingleActivator> aliases;
  final bool enabled;

  /// Placeholder rows such as "No Recent Runs" fill an empty menu but are
  /// not commands; they do not belong in the palette.
  final bool inPalette;

  /// The Alt-access letter on the in-window menu bar, Windows and Linux
  /// only. Assigned to the app's own static commands — File, Edit, Find,
  /// View, Window and the Text menu's head — never to per-tool rows, whose
  /// labels come from the localizable shared catalog. Null leaves the label
  /// unmarked.
  final String? mnemonic;
}

/// The placeholder for an empty Recent submenu — it can never be chosen.
void _noop() {}

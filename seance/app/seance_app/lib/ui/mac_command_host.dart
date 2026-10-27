import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorZoom;
import 'package:seance_core/seance_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/mac_commands.dart';
import '../services/window_state.dart';
import 'app_menus.dart';
import 'inspector_page.dart';
import 'keyboard_shortcuts_dialog.dart';
import 'server_actions.dart';
import 'server_editor.dart';
import 'server_list_density.dart';
import 'server_list_pane.dart';
import 'session_label.dart';
import 'tab_close.dart';
import 'terminal_appearance.dart';
import 'terminal_pane.dart';
import 'top_toast.dart';

/// Counts the dialogs and menus open over the app's routes, so the menu bar
/// can stand down while one is up, as a Mac app's does under a sheet.
final class ModalRouteTracker extends NavigatorObserver {
  final ValueNotifier<int> open = ValueNotifier(0);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) open.value++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) open.value--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) open.value--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PopupRoute) open.value--;
    if (newRoute is PopupRoute) open.value++;
  }
}

/// The root navigator's [ModalRouteTracker] (MaterialApp's observer).
final ModalRouteTracker modalRoutes = ModalRouteTracker();

/// Where Help ▸ Séance Help leads: the product's documentation.
final Uri seanceHelpUri = Uri.parse(
  'https://github.com/L-K-M/Hauntware/blob/main/seance/README.md',
);

/// The most servers the Dock menu lists.
const int _dockServerLimit = 20;

/// Runs the macOS menu bar, toolbar and Dock menu (MainMenu.swift) over the
/// app: publishes every [AppCommand]'s state as the app, the focus and the
/// open dialogs change, runs what the user chooses, keeps the window's
/// title on the active session, and asks before a quit that would end
/// sessions or lose edits.
///
///     AppState ─┐                       ┌─▶ setCommandStates
///     focus    ─┼─▶ _schedule ─(frame)─▶┤
///     dialogs  ─┘                       └─▶ setWindowTitle
///     menu item / toolbar / Dock ──run──▶ runCommand
class MacCommandHost extends StatefulWidget {
  const MacCommandHost({super.key, required this.child, this.bridge});

  final Widget child;

  /// Test seam: the channel's Dart end.
  final MacCommandBridge? bridge;

  @override
  State<MacCommandHost> createState() => _MacCommandHostState();
}

class _MacCommandHostState extends State<MacCommandHost>
    with WidgetsBindingObserver
    implements MacCommandHandler {
  late final MacCommandBridge _bridge = widget.bridge ?? MacCommandBridge();
  AppState? _state;

  /// The terminal view and editor whose own changes (selection, focus,
  /// unsaved text) move menu states, while they are the active ones.
  TerminalViewCommands? _terminal;
  EditorTab? _editor;

  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bridge.handler = this;
    FocusManager.instance.addListener(_schedule);
    activeTerminalView.addListener(_followTerminal);
    modalRoutes.open.addListener(_schedule);
    WindowStateService.mainWindowShown.addListener(_windowShownChanged);
    // Selections in text fields change with no notification anyone can
    // hear; the input that makes them is the next best thing.
    HardwareKeyboard.instance.addHandler(_afterKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_afterPointer);
    _followTerminal();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (identical(state, _state)) return;
    _state?.removeListener(_schedule);
    _state?.undoHistory.removeListener(_schedule);
    _state = state
      ..addListener(_schedule)
      ..undoHistory.addListener(_schedule);
    _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bridge.handler = null;
    FocusManager.instance.removeListener(_schedule);
    activeTerminalView.removeListener(_followTerminal);
    _terminal?.changes.removeListener(_schedule);
    _editor?.dirty.removeListener(_schedule);
    modalRoutes.open.removeListener(_schedule);
    WindowStateService.mainWindowShown.removeListener(_windowShownChanged);
    HardwareKeyboard.instance.removeHandler(_afterKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_afterPointer);
    _state?.removeListener(_schedule);
    _state?.undoHistory.removeListener(_schedule);
    super.dispose();
  }

  bool _afterKey(KeyEvent event) {
    if (event is KeyUpEvent) _schedule();
    return false;
  }

  void _afterPointer(PointerEvent event) {
    if (event is PointerUpEvent) _schedule();
  }

  void _followTerminal() {
    final terminal = activeTerminalView.value;
    if (identical(terminal, _terminal)) return;
    _terminal?.changes.removeListener(_schedule);
    _terminal = terminal?..changes.addListener(_schedule);
    _schedule();
  }

  void _windowShownChanged() => _schedule();

  /// While the window is closed its sessions run on; the Dock says how
  /// many, as Mail counts unread mail there.
  void _updateDockBadge(AppState state) {
    final shown = WindowStateService.mainWindowShown.value;
    final live = _liveSessions(state).length;
    unawaited(_bridge.setDockBadge(shown || live == 0 ? null : '$live'));
  }

  /// Publishes once, after the frame the change lands in.
  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _publish();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _publish() {
    final state = _state;
    if (state == null) return;
    final active = state.activeTab;
    final editor = active is EditorTab ? active : null;
    if (!identical(editor, _editor)) {
      _editor?.dirty.removeListener(_schedule);
      _editor = editor?..dirty.addListener(_schedule);
    }
    unawaited(
      _bridge.publish(_states(state), dockServers: _dockServers(state)),
    );
    final (title, subtitle) = _windowTitle(state);
    unawaited(_bridge.setWindowTitle(title, subtitle));
    _updateDockBadge(state);
  }

  // -- state ---------------------------------------------------------------

  /// The terminal view showing the active tab, if one is.
  TerminalViewCommands? _activeTerminal(AppState state) {
    final terminal = _terminal;
    if (terminal == null || !identical(terminal.tab, state.activeTab)) {
      return null;
    }
    return terminal;
  }

  Map<AppCommand, CommandState> _states(AppState state) {
    final modal = modalRoutes.open.value > 0;
    final shown = WindowStateService.mainWindowShown.value;
    // Commands on the window's content wait for it to be on screen and
    // free of dialogs; the ones that create something bring it back.
    final free = !modal;
    final content = free && shown;
    final active = state.activeTab;
    final session = active is TerminalSession ? active : null;
    final editor = active is EditorTab ? active : null;
    final server = active == null ? null : state.configFor(active.serverId);
    final terminal = _activeTerminal(state);
    final editorState = editor?.editorKey.currentState;
    final status = session?.status;
    final connected = status == TerminalStatus.connected;
    final local = session?.isLocal ?? false;
    final strip = active == null
        ? const <PaneTab>[]
        : state.tabsForServer(active.serverId);

    CommandState on(bool enabled, {String? title, bool? checked}) =>
        CommandState(enabled: enabled, title: title, checked: checked);
    CommandState page(InspectorPage page) => on(
      content,
      checked: state.inspectorVisible && state.inspectorPage == page,
    );

    return {
      AppCommand.checkForUpdates: on(free),
      AppCommand.settings: on(true),
      AppCommand.newServer: on(free),
      AppCommand.newTab: on(free && active != null),
      AppCommand.newLocalShell: on(free && state.localShellAvailable),
      AppCommand.closeTab: on(content && active != null),
      AppCommand.closeWindow: on(content),
      AppCommand.save: on(
        content && editorState != null,
        title: editorState?.canUpload ?? false ? 'Save and Upload' : 'Save',
      ),
      AppCommand.saveLocally: on(content && (editorState?.canUpload ?? false)),
      AppCommand.exportText: on(content && session != null),
      AppCommand.importSshConfig: on(free),
      ..._editStates(state, content: shown),
      AppCommand.clearScrollback: on(content && terminal != null),
      AppCommand.find: on(content && terminal != null),
      AppCommand.findNext: on(content && terminal != null),
      AppCommand.findPrevious: on(content && terminal != null),
      AppCommand.useSelectionForFind: on(
        content && (terminal?.hasSelection ?? false),
      ),
      AppCommand.toggleSidebar: on(
        content,
        title: state.sidebarVisible ? 'Hide Sidebar' : 'Show Sidebar',
      ),
      AppCommand.toggleInspector: on(
        content,
        title: state.inspectorVisible ? 'Hide Inspector' : 'Show Inspector',
      ),
      AppCommand.showFiles: page(InspectorPage.files),
      AppCommand.showGit: page(InspectorPage.git),
      AppCommand.showSnippets: page(InspectorPage.snippets),
      AppCommand.showAssistant: page(InspectorPage.assistant),
      AppCommand.toggleDensity: on(
        content,
        title: switch (state.serverListDensity) {
          ServerListDensity.comfortable => 'Use Compact Sidebar Rows',
          ServerListDensity.compact => 'Use Comfortable Sidebar Rows',
        },
      ),
      AppCommand.actualSize: on(content),
      AppCommand.zoomIn: on(content),
      AppCommand.zoomOut: on(content),
      AppCommand.connectToServer: on(free),
      AppCommand.reconnect: on(
        content &&
            (status == TerminalStatus.disconnected ||
                status == TerminalStatus.error),
      ),
      AppCommand.disconnect: on(
        content && connected,
        title: local ? 'End Shell' : 'Disconnect',
      ),
      AppCommand.connection: on(
        content && session != null && status != TerminalStatus.connecting,
        checked: connected,
        title: connected ? (local ? 'End Shell' : 'Disconnect') : 'Reconnect',
      ),
      AppCommand.editServer: on(content && server != null),
      AppCommand.duplicateServer: on(content && server != null),
      AppCommand.togglePin: on(
        content && server != null,
        title: server != null && state.isServerPinned(server.id)
            ? 'Unpin'
            : 'Pin to Top',
      ),
      AppCommand.copySshCommand: on(content && server != null),
      AppCommand.deleteServer: on(content && server != null),
      AppCommand.generateCommand: on(content && session != null),
      AppCommand.previousTab: on(content && strip.length > 1),
      AppCommand.nextTab: on(content && strip.length > 1),
      AppCommand.showMainWindow: on(true),
      AppCommand.help: on(true),
      AppCommand.keyboardShortcuts: on(free && shown),
    };
  }

  /// Edit commands for whatever holds focus: the terminal, a text field
  /// (a dialog's included), or nothing that edits. A command no focused
  /// control takes is left disabled, so its key still reaches Flutter and
  /// whatever handles it there (the built-in editor's own bindings).
  Map<AppCommand, CommandState> _editStates(
    AppState state, {
    required bool content,
  }) {
    const off = CommandState.disabled;
    const on = CommandState.available;
    final free = content && modalRoutes.open.value == 0;
    // The app's own history, where no text field has one of its own.
    final history = state.undoHistory;
    final undoName = free ? history.undoName : null;
    final redoName = free ? history.redoName : null;
    final appUndo = undoName == null
        ? off
        : CommandState(enabled: true, title: 'Undo $undoName');
    final appRedo = redoName == null
        ? off
        : CommandState(enabled: true, title: 'Redo $redoName');
    final terminal = _activeTerminal(state);
    if (free && terminal != null && terminal.terminalFocused) {
      return {
        AppCommand.undo: appUndo,
        AppCommand.redo: appRedo,
        AppCommand.cut: off,
        AppCommand.copy: terminal.hasSelection ? on : off,
        AppCommand.paste: on,
        AppCommand.selectAll: on,
      };
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    CommandState can<T extends Intent>(T intent) {
      if (focus == null || !focus.mounted) return off;
      final action = Actions.maybeFind<T>(focus, intent: intent);
      return action != null && action.isEnabled(intent) ? on : off;
    }

    final textField = _editsText(focus);
    return {
      AppCommand.undo: textField ? can(_undo) : appUndo,
      AppCommand.redo: textField ? can(_redo) : appRedo,
      AppCommand.cut: can(_cut),
      AppCommand.copy: can(CopySelectionTextIntent.copy),
      AppCommand.paste: can(_paste),
      AppCommand.selectAll: can(_selectAll),
    };
  }

  static const _cause = SelectionChangedCause.keyboard;
  static const _undo = UndoTextIntent(_cause);
  static const _redo = RedoTextIntent(_cause);
  static const _cut = CopySelectionTextIntent.cut(_cause);
  static const _paste = PasteTextIntent(_cause);
  static const _selectAll = SelectAllTextIntent(_cause);

  List<DockServer> _dockServers(AppState state) {
    final pinned = state.pinnedServerIds;
    final servers = [
      ...state.servers.where((s) => pinned.contains(s.id)),
      ...state.servers.where((s) => !pinned.contains(s.id)),
    ];
    return [
      for (final server in servers.take(_dockServerLimit))
        (id: server.id, label: server.label),
    ];
  }

  (String, String) _windowTitle(AppState state) {
    final active = state.activeTab;
    if (active == null) return ('Séance', '');
    final server = state.configFor(active.serverId) ?? active.config;
    if (active is EditorTab) {
      return (editorTabLabel(active.remotePath), server?.label ?? '');
    }
    if (server == null) {
      final session = active as TerminalSession;
      return (session.displayLabel, session.displayTarget);
    }
    return (server.label, _address(server));
  }

  static String _address(ServerConfig server) {
    final port = server.port == 22 ? '' : ':${server.port}';
    return server.username.isEmpty
        ? '${server.host}$port'
        : '${server.username}@${server.host}$port';
  }

  static List<TerminalSession> _liveSessions(AppState state) => [
    for (final tab in state.tabs)
      if (tab is TerminalSession &&
          (tab.status == TerminalStatus.connected ||
              tab.status == TerminalStatus.connecting))
        tab,
  ];

  // -- running -------------------------------------------------------------

  @override
  Future<void> openServer(String serverId) async {
    final state = _state;
    if (state == null) return;
    final server = state.configFor(serverId);
    if (server == null) return;
    await WindowStateService.showMainWindow();
    await state.openTerminal(server);
  }

  @override
  Future<void> runCommand(AppCommand command) async {
    final state = _state;
    if (state == null || !mounted) return;
    final active = state.activeTab;
    final session = active is TerminalSession ? active : null;
    final server = active == null ? null : state.configFor(active.serverId);
    final terminal = _activeTerminal(state);
    switch (command) {
      case AppCommand.checkForUpdates:
        await _checkForUpdates(state);
      case AppCommand.settings:
        openSettings();
      case AppCommand.newServer:
        await WindowStateService.showMainWindow();
        if (mounted) await showServerEditor(context, state, null);
      case AppCommand.newTab:
        await WindowStateService.showMainWindow();
        if (active != null) await state.duplicateTab(active);
      case AppCommand.newLocalShell:
        await WindowStateService.showMainWindow();
        await state.newLocalTab();
      case AppCommand.closeTab:
        if (active != null) await confirmAndCloseTab(context, state, active.id);
      case AppCommand.closeWindow:
        await windowManager.close();
      case AppCommand.save || AppCommand.saveLocally:
        final editor = active is EditorTab
            ? active.editorKey.currentState
            : null;
        await editor?.save(upload: command == AppCommand.save);
      case AppCommand.exportText:
        if (session != null) await _exportText(session);
      case AppCommand.importSshConfig:
        await WindowStateService.showMainWindow();
        if (mounted) await importSshConfigInteractively(context, state);
      case AppCommand.undo ||
          AppCommand.redo ||
          AppCommand.cut ||
          AppCommand.copy ||
          AppCommand.paste ||
          AppCommand.selectAll:
        await _runEdit(state, command);
      case AppCommand.clearScrollback:
        terminal?.clearScrollback();
      case AppCommand.find:
        terminal?.openFind();
      case AppCommand.findNext:
        terminal?.findNext();
      case AppCommand.findPrevious:
        terminal?.findPrevious();
      case AppCommand.useSelectionForFind:
        terminal?.useSelectionForFind();
      case AppCommand.toggleSidebar:
        await state.setSidebarVisible(!state.sidebarVisible);
      case AppCommand.toggleInspector:
        await state.setInspectorVisible(!state.inspectorVisible);
      case AppCommand.showFiles:
        await _showInspector(state, InspectorPage.files);
      case AppCommand.showGit:
        await _showInspector(state, InspectorPage.git);
      case AppCommand.showSnippets:
        await _showInspector(state, InspectorPage.snippets);
      case AppCommand.showAssistant:
        await _showInspector(state, InspectorPage.assistant);
      case AppCommand.toggleDensity:
        await state.setServerListDensity(switch (state.serverListDensity) {
          ServerListDensity.comfortable => ServerListDensity.compact,
          ServerListDensity.compact => ServerListDensity.comfortable,
        });
      case AppCommand.actualSize:
        await _zoom(state, EditorZoom.actualSize, null);
      case AppCommand.zoomIn:
        await _zoom(state, EditorZoom.zoomIn, kTerminalFontSizeStep);
      case AppCommand.zoomOut:
        await _zoom(state, EditorZoom.zoomOut, -kTerminalFontSizeStep);
      case AppCommand.connectToServer:
        await _connectToServer(state);
      case AppCommand.reconnect:
        if (session != null) await state.reconnect(session.id);
      case AppCommand.disconnect:
        if (session != null) await state.disconnect(session.id);
      case AppCommand.connection:
        if (session == null) return;
        if (session.status == TerminalStatus.connected) {
          await state.disconnect(session.id);
        } else {
          await state.reconnect(session.id);
        }
      case AppCommand.editServer:
        if (server != null) await showServerEditor(context, state, server);
      case AppCommand.duplicateServer:
        if (server != null) {
          await duplicateServerInteractively(context, state, server);
        }
      case AppCommand.togglePin:
        if (server != null) await toggleServerPinUndoably(state, server);
      case AppCommand.copySshCommand:
        if (server != null) await _copySshCommand(server);
      case AppCommand.deleteServer:
        if (server != null) await confirmDeleteServer(context, state, server);
      case AppCommand.generateCommand:
        openCommandGenerator(state);
      case AppCommand.previousTab:
        stepActiveTab(state, -1);
      case AppCommand.nextTab:
        stepActiveTab(state, 1);
      case AppCommand.showMainWindow:
        await WindowStateService.showMainWindow();
      case AppCommand.help:
        await launchUrl(seanceHelpUri);
      case AppCommand.keyboardShortcuts:
        await showKeyboardShortcuts(context);
    }
  }

  Future<void> _runEdit(AppState state, AppCommand command) async {
    final terminal = _activeTerminal(state);
    final focus = FocusManager.instance.primaryFocus?.context;
    final textField = _editsText(focus);
    if (!textField &&
        (command == AppCommand.undo || command == AppCommand.redo)) {
      await _stepHistory(state, command);
      return;
    }
    if (modalRoutes.open.value == 0 &&
        terminal != null &&
        terminal.terminalFocused) {
      final tab = terminal.tab;
      switch (command) {
        case AppCommand.copy:
          terminalCopy(tab);
        case AppCommand.paste:
          await terminalPaste(tab);
        case AppCommand.selectAll:
          terminalSelectAll(tab);
        default:
          break;
      }
      return;
    }
    if (focus == null || !focus.mounted) return;
    void invoke<T extends Intent>(T intent) {
      final action = Actions.maybeFind<T>(focus, intent: intent);
      if (action == null || !action.isEnabled(intent)) return;
      Actions.invoke<T>(focus, intent);
    }

    switch (command) {
      case AppCommand.undo:
        invoke(_undo);
      case AppCommand.redo:
        invoke(_redo);
      case AppCommand.cut:
        invoke(_cut);
      case AppCommand.copy:
        invoke(CopySelectionTextIntent.copy);
      case AppCommand.paste:
        invoke(_paste);
      case AppCommand.selectAll:
        invoke(_selectAll);
      default:
        break;
    }
  }

  /// Whether [focus] keeps a text undo history of its own: a text field,
  /// or the built-in editor, both of which answer [UndoTextIntent].
  static bool _editsText(BuildContext? focus) =>
      focus != null &&
      focus.mounted &&
      Actions.maybeFind<UndoTextIntent>(focus, intent: _undo) != null;

  /// Edit ▸ Undo and Redo outside text fields: the app's own history.
  Future<void> _stepHistory(AppState state, AppCommand command) async {
    final history = state.undoHistory;
    final name = command == AppCommand.undo
        ? history.undoName
        : history.redoName;
    if (name == null) return;
    try {
      if (command == AppCommand.undo) {
        await history.undo();
      } else {
        await history.redo();
      }
    } catch (error) {
      if (mounted) {
        final verb = command == AppCommand.undo ? 'undo' : 'redo';
        showTopToastIn(context, message: 'Couldn’t $verb $name — $error');
      }
    }
  }

  Future<void> _showInspector(AppState state, InspectorPage page) async {
    await state.setInspectorVisible(true);
    await state.setInspectorPage(page);
  }

  /// View ▸ Zoom: the active editor's text, or every terminal's.
  Future<void> _zoom(AppState state, EditorZoom zoom, double? delta) async {
    try {
      if (state.activeTab is EditorTab) {
        await state.zoomEditor(zoom);
      } else {
        await state.zoomTerminal(delta);
      }
    } catch (error) {
      if (mounted) showTopToastIn(context, message: 'Size not saved — $error');
    }
  }

  /// Server ▸ Connect to Server…: the list's filter, where typing narrows
  /// the servers and Return opens the first. The list comes back first if
  /// it was hidden; a window too narrow to show it says so rather than
  /// doing nothing.
  Future<void> _connectToServer(AppState state) async {
    await WindowStateService.showMainWindow();
    if (state.sidebarVisible && ServerListPane.revealFilter()) return;
    await state.setSidebarVisible(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ServerListPane.revealFilter() || !mounted) return;
      showTopToastIn(
        context,
        message: 'Make the window wider to show the server list.',
      );
    });
  }

  Future<void> _copySshCommand(ServerConfig server) async {
    final port = server.port == 22 ? '' : ' -p ${server.port}';
    final target = server.username.isEmpty
        ? server.host
        : '${server.username}@${server.host}';
    await Clipboard.setData(ClipboardData(text: 'ssh$port $target'));
    if (mounted) showTopToastIn(context, message: 'Copied the ssh command.');
  }

  /// File ▸ Export Text As…: the session's scrollback and screen, as plain
  /// text, where a save panel says.
  Future<void> _exportText(TerminalSession session) async {
    final buffer = session.engine.terminal.buffer;
    final text = buffer.getText();
    final name = '${session.displayLabel.replaceAll('/', '-')}.txt';
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'Export Text As',
        fileName: name,
      );
      if (path == null) return;
      await File(path).writeAsString(text, encoding: utf8);
    } catch (error) {
      if (mounted) showTopToastIn(context, message: 'Not exported — $error');
    }
  }

  /// Séance ▸ Check for Updates…: asks GitHub now and says what it found.
  Future<void> _checkForUpdates(AppState state) async {
    final String version;
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (error) {
      if (mounted) showTopToastIn(context, message: 'No version to check.');
      return;
    }
    final info = await state.checkForUpdateNow(version);
    if (info == null) {
      await showMacAlert(
        message: 'No update found',
        informative:
            'Séance couldn’t find a release newer than $version. If this '
            'Mac is offline, try again later.',
        buttons: const ['OK'],
      );
      return;
    }
    const open = 0;
    final answer = await showMacAlert(
      message: 'Séance ${info.latestVersion} is available',
      informative: 'You have $version. The release page has the download.',
      buttons: const ['Open Release Page', 'Later'],
    );
    if (answer?.button == open) await launchUrl(info.releasesUrl);
  }

  // -- quitting ------------------------------------------------------------

  /// ⌘Q and the Dock's Quit: asks first when the quit would lose unsaved
  /// text in an editor or end live sessions, as Terminal and TextEdit do.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    final state = _state;
    if (state == null) return AppExitResponse.exit;
    final dirty = [
      for (final tab in state.tabs)
        if (tab is EditorTab && tab.dirty.value) tab,
    ];
    if (dirty.isNotEmpty) return _confirmQuitWithUnsaved(state, dirty);
    final live = _liveSessions(state);
    if (live.isEmpty) return AppExitResponse.exit;
    final count = live.length;
    const quit = 0;
    final answer = await showMacAlert(
      message: 'Quit Séance?',
      informative: count == 1
          ? '“${live.single.displayLabel}” is connected. Quitting ends '
                'the session.'
          : '$count sessions are connected. Quitting ends them.',
      buttons: const ['Quit', 'Cancel'],
    );
    return answer?.button == quit
        ? AppExitResponse.exit
        : AppExitResponse.cancel;
  }

  Future<AppExitResponse> _confirmQuitWithUnsaved(
    AppState state,
    List<EditorTab> dirty,
  ) async {
    const review = 0;
    const discard = 2;
    final count = dirty.length;
    final answer = await showMacAlert(
      message: count == 1
          ? 'Do you want to save the changes you made to '
                '“${editorTabLabel(dirty.single.remotePath)}”?'
          : 'You have $count files with unsaved changes. Do you want to '
                'review these changes before quitting?',
      informative: 'If you don’t review them, your changes will be lost.',
      buttons: [
        count == 1 ? 'Review…' : 'Review Changes…',
        'Cancel',
        'Discard Changes',
      ],
      destructive: discard,
    );
    switch (answer?.button) {
      case discard:
        return AppExitResponse.exit;
      case review:
        await WindowStateService.showMainWindow();
        state.focusTab(dirty.first.id);
    }
    return AppExitResponse.cancel;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

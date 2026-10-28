import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostChordBinding, dispatchGhostChord;

import '../app_state.dart';
import '../main.dart';
import '../services/local_settings_backend.dart';
import 'command_generator.dart';
import 'inspector_page.dart';
import 'server_list_density.dart';
import 'server_list_pane.dart';
import 'settings_screen.dart';
import 'tab_close.dart';
import 'top_toast.dart';

bool _settingsRouteOpen = false;

/// Open Settings on [initialTab]: in its own window on desktop, as a route on
/// the root navigator elsewhere — and on desktop too when the runner cannot
/// open the window. Safe to call from menu callbacks and shortcuts (needs no
/// [BuildContext]); choosing Settings again brings the open window forward on
/// the new tab rather than opening a second one.
void openSettings([SettingsTab initialTab = SettingsTab.general]) {
  final host = settingsWindowHost;
  if (host == null) {
    _openSettingsRoute(initialTab);
    return;
  }
  unawaited(
    host
        .open(initialTab)
        .then(
          (opened) {
            if (!opened) _openSettingsRoute(initialTab);
          },
          onError: (Object error) {
            // The runner refused to open it; Settings must still be reachable.
            debugPrint('Settings window failed to open: $error');
            _openSettingsRoute(initialTab);
          },
        ),
  );
}

/// Settings as a route; guards against stacking duplicate Settings routes
/// when triggered repeatedly.
void _openSettingsRoute(SettingsTab initialTab) {
  if (_settingsRouteOpen) return;
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  _settingsRouteOpen = true;
  nav
      .push(
        MaterialPageRoute(
          builder: (context) => SettingsScreen(
            backend: LocalSettingsBackend(AppScope.of(context)),
            initialTab: initialTab,
          ),
        ),
      )
      .whenComplete(() => _settingsRouteOpen = false);
}

/// Open the command generator for the active session. Used by the macOS menu
/// item and ⌘K; nudges the user to Settings if the assistant isn't set up.
void openCommandGenerator(AppState state) {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  if (!state.llmConfigured) {
    showTopToastIn(ctx, message: 'Configure the assistant in Settings first.');
    return;
  }
  showCommandGenerator(ctx, state);
}

/// Open another terminal session for the currently selected server.
void openNewTab(AppState state) {
  final active = state.activeSession;
  if (active != null) state.duplicateTab(active);
}

/// Copy the active terminal's selection to the clipboard. Returns false when
/// nothing is selected (so a keypress can fall through). Shared by the terminal
/// right-click menu, the keyboard shortcut, and the native macOS Edit ▸ Copy.
bool terminalCopy(TerminalSession tab) {
  final controller = tab.controller;
  if (controller == null) return false;
  final selection = controller.selection;
  if (selection == null) return false;
  final text = tab.engine.terminal.buffer.getText(selection);
  if (text.isEmpty) return false;
  Clipboard.setData(ClipboardData(text: text));
  return true;
}

/// Paste clipboard text into the active terminal (honours bracketed-paste mode).
Future<void> terminalPaste(TerminalSession tab) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text != null && text.isNotEmpty) {
    tab.engine.terminal.paste(text);
  }
}

/// Select the active terminal's whole buffer (scrollback included).
void terminalSelectAll(TerminalSession tab) {
  final controller = tab.controller;
  if (controller == null) return;
  final terminal = tab.engine.terminal;
  final buffer = terminal.buffer;
  // Start at row 0 so scrollback is included. (The old start of
  // `buffer.height - viewHeight` is the top of the *visible* page, which
  // silently dropped everything scrolled off — contradicting this function's
  // own "scrollback included" contract.)
  controller.setSelection(
    buffer.createAnchor(0, 0),
    buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
  );
}

/// The channel the native macOS menu (MainFlutterWindow.swift) and Dart
/// talk over, both ways.
const MethodChannel macMenuChannel = MethodChannel('seance/menu');

/// Wire the native macOS menu items to app actions, and keep the one item
/// whose title Dart owns in step: View's density item, which names the
/// density it switches to ("Use Compact Sidebar Rows"). One item with a
/// flipping title rather than a checked pair, the pattern Poltergeist's
/// View menu uses for the same command (sibling contract §10.5).
void installMacMenu(AppState state, {MethodChannel channel = macMenuChannel}) {
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'newTab':
        openNewTab(state);
      case 'openSettings':
        openSettings();
      case 'generateCommand':
        openCommandGenerator(state);
      case 'toggleServerListDensity':
        await state.setServerListDensity(switch (state.serverListDensity) {
          ServerListDensity.comfortable => ServerListDensity.compact,
          ServerListDensity.compact => ServerListDensity.comfortable,
        });
      // Native Edit menu, forwarded only when a terminal is focused.
      case 'editCopy':
        if (state.activeSession != null) terminalCopy(state.activeSession!);
      case 'editPaste':
        if (state.activeSession != null) {
          await terminalPaste(state.activeSession!);
        }
      case 'editSelectAll':
        if (state.activeSession != null) {
          terminalSelectAll(state.activeSession!);
        }
    }
    return null;
  });

  // Retitled on every density change, from the menu or either switch, and
  // on nothing else: the state notifies for far more than this.
  ServerListDensity? titled;
  void retitle() {
    final density = state.serverListDensity;
    if (density == titled) return;
    titled = density;
    unawaited(
      channel.invokeMethod<void>(
        'setServerListDensityTitle',
        _densityMenuTitle(density),
      ),
    );
  }

  retitle();
  state.addListener(retitle);
}

/// The View menu's density item at [current]: the choice it switches to.
String _densityMenuTitle(ServerListDensity current) => switch (current) {
  ServerListDensity.comfortable => 'Use Compact Sidebar Rows',
  ServerListDensity.compact => 'Use Comfortable Sidebar Rows',
};

/// The server filter's chord (Poltergeist's plan, 10 §5): ⌥⌘F on Apple
/// platforms, Ctrl+Alt+F elsewhere.
SingleActivator serverFilterActivator(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => const SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: true,
        alt: true,
      ),
      _ => const SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        alt: true,
      ),
    };

/// [serverFilterActivator] as the app-wide binding takes it. On Windows it
/// stands down while the right Alt is held: Windows reports AltGr as Ctrl +
/// right Alt, AltGr+F types "[" on Czech, Slovak, Hungarian and other
/// layouts, and a handled key would swallow that character in every field
/// and terminal under [AppMenus]. The chord itself uses the left Alt.
final class _ServerFilterChord extends ShortcutActivator {
  const _ServerFilterChord(this._platform);

  final TargetPlatform _platform;

  SingleActivator get _chord => serverFilterActivator(_platform);

  @override
  Iterable<LogicalKeyboardKey>? get triggers => _chord.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      _chord.accepts(event, state) &&
      !(_platform == TargetPlatform.windows &&
          state.logicalKeysPressed.contains(LogicalKeyboardKey.altRight));

  @override
  String debugDescribeKeys() => _chord.debugDescribeKeys();
}

/// What a tab shortcut does. Each acts on the active tab's server: the
/// strip only ever shows one server's tabs, so stepping never leaves it.
sealed class TabCommand {
  const TabCommand();

  /// Whether holding the keys repeats the command. Only stepping does: a
  /// held close would take out a row of tabs before the key came back up.
  bool get repeats => false;
}

/// Close the active tab, behind its close button's guards
/// ([confirmAndCloseTab]).
final class CloseTabCommand extends TabCommand {
  const CloseTabCommand();
}

/// Move [step] tabs along the strip (1 the next, -1 the previous), wrapping
/// round at either end.
final class StepTabCommand extends TabCommand {
  const StepTabCommand(this.step);

  final int step;

  @override
  bool get repeats => true;
}

/// Show the [number]th tab, counting from 1. [last] is the last tab however
/// many there are, as in browsers and other terminals; any other number
/// past the end does nothing.
final class GoToTabCommand extends TabCommand {
  const GoToTabCommand(this.number);

  static const int last = 9;

  final int number;
}

/// One tab shortcut: [chord] runs [command].
final class TabShortcut {
  const TabShortcut._(this.chord, this.command, {this.leftAltOnly = false});

  /// Accepts held repeats (the [SingleActivator] default), so a held chord
  /// is still recognized when its command does not repeat, and swallowed.
  final SingleActivator chord;

  final TabCommand command;

  /// The chord stands down while the right Alt is held (see [tabShortcuts]).
  final bool leftAltOnly;
}

/// The tab shortcuts on [platform]: one table for both places that honour
/// them, the terminal's key handler, which has to see them before xterm
/// turns them into bytes for the shell, and [AppMenus], for focus anywhere
/// else in the window.
///
/// Apple platforms use ⌘, which never reaches a shell. Elsewhere the chords
/// stay off what a shell reads: close is Ctrl+Shift+W because plain Ctrl+W
/// is readline's word erase, and the numbers are Alt+1 to Alt+9 (GNOME
/// Terminal's), which does take readline's digit-argument prefix (Alt+3,
/// then a key typed three times) away from the shell. Only the left Alt
/// counts: the right one is AltGr on most non-US layouts, where AltGr+digit
/// types @, #, [, ] and more, and a handled key would swallow the character
/// (Windows reports AltGr as Ctrl + right Alt, and some Linux setups as the
/// right Alt). Only the top-row digits count too: on Windows, Alt with the
/// keypad's types a character by its code (Alt+0169 is ©).
///
/// Ctrl+Tab and Ctrl+Shift+Tab step on every platform: unlike ⇧⌘] and ⇧⌘[,
/// they need no bracket keys, which many layouts put behind Option.
List<TabShortcut> tabShortcuts(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => _appleTabShortcuts,
  _ => _otherTabShortcuts,
};

const List<LogicalKeyboardKey> _tabNumberKeys = [
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

const List<TabShortcut> _ctrlTabShortcuts = [
  TabShortcut._(
    SingleActivator(LogicalKeyboardKey.tab, control: true),
    StepTabCommand(1),
  ),
  TabShortcut._(
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
    StepTabCommand(-1),
  ),
];

final List<TabShortcut> _appleTabShortcuts = [
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.keyW, meta: true),
    CloseTabCommand(),
  ),
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.bracketRight, meta: true, shift: true),
    StepTabCommand(1),
  ),
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true, shift: true),
    StepTabCommand(-1),
  ),
  ..._ctrlTabShortcuts,
  for (final (i, key) in _tabNumberKeys.indexed)
    TabShortcut._(SingleActivator(key, meta: true), GoToTabCommand(i + 1)),
];

final List<TabShortcut> _otherTabShortcuts = [
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true),
    CloseTabCommand(),
  ),
  ..._ctrlTabShortcuts,
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.pageDown, control: true),
    StepTabCommand(1),
  ),
  const TabShortcut._(
    SingleActivator(LogicalKeyboardKey.pageUp, control: true),
    StepTabCommand(-1),
  ),
  for (final (i, key) in _tabNumberKeys.indexed)
    TabShortcut._(
      SingleActivator(key, alt: true),
      GoToTabCommand(i + 1),
      leftAltOnly: true,
    ),
];

/// Run the tab shortcut [event] is, if it is one ([tabShortcuts]): the one
/// decision behind both places they work, so the two cannot drift. A match
/// is always handled, even a held repeat its command does not act on:
/// ignored, the terminal would send it to the shell as the keys underneath
/// (Ctrl+Shift+W is ^W there, Alt+1 is Esc 1).
KeyEventResult handleTabShortcut(
  BuildContext context,
  AppState state,
  KeyEvent event,
) => dispatchGhostChord([
  for (final shortcut in tabShortcuts(Theme.of(context).platform))
    GhostChordBinding(
      activator: shortcut.chord,
      repeats: shortcut.command.repeats,
      leftAltOnly: shortcut.leftAltOnly,
      onInvoke: () => _runTabCommand(context, state, shortcut.command),
    ),
], event);

void _runTabCommand(BuildContext context, AppState state, TabCommand command) {
  final active = state.activeTab;
  if (active == null) return;
  final strip = state.tabsForServer(active.serverId);
  switch (command) {
    case CloseTabCommand():
      unawaited(confirmAndCloseTab(context, state, active.id));
    case StepTabCommand(:final step):
      // Dart's % is never negative for a positive divisor: -1 wraps to the end.
      state.focusTab(strip[(strip.indexOf(active) + step) % strip.length].id);
    case GoToTabCommand(:final number):
      final index = number == GoToTabCommand.last
          ? strip.length - 1
          : number - 1;
      if (index < strip.length) state.focusTab(strip[index].id);
  }
}

/// What a window shortcut does: show or hide a side pane, open an
/// inspector page, or step the app's undo history ([AppUndoHistory]).
enum WindowCommand {
  toggleSidebar,
  toggleInspector,
  showFiles,
  showGit,
  showSnippets,
  showAssistant,
  undo,
  redo;

  /// Whether the command steps the app's undo history, which stands down
  /// wherever a text field or the editor keeps a history of its own.
  bool get stepsHistory => this == undo || this == redo;
}

/// Where a key reached the window shortcuts from. The terminal hands keys
/// to them before xterm turns them into bytes for the shell.
enum ShortcutOrigin { terminal, window }

/// One window shortcut: [chord] runs [command].
final class WindowShortcut {
  const WindowShortcut._(this.chord, this.command, {this.leftAltOnly = false});

  final SingleActivator chord;
  final WindowCommand command;

  /// The chord stands down while the right Alt is held, as the tab
  /// numbers do ([tabShortcuts]): AltGr+digit types a character on many
  /// layouts.
  final bool leftAltOnly;
}

/// The window shortcuts on [platform], one table for both places that
/// honour them, as [tabShortcuts] is.
///
/// The panes take Poltergeist's chords: ⌃⌘S for the sidebar and ⌥⌘I for
/// the inspector on Apple platforms, Ctrl+Alt+S and Ctrl+Alt+I elsewhere,
/// with the inspector's pages on the digits beside them (⌥⌘1 to ⌥⌘4,
/// Ctrl+Alt+1 to Ctrl+Alt+4). Off Apple platforms only the left Alt
/// counts, as for the tab numbers: Windows reports AltGr as Ctrl + right
/// Alt, and AltGr+S types ś on Polish layouts. xterm has no bytes for
/// Ctrl+Alt+letter, so the terminal loses nothing to them. Undo is ⌘Z and
/// ⇧⌘Z, or Ctrl+Z, Ctrl+Shift+Z and Ctrl+Y, which the terminal leaves to
/// the shell ([handleWindowShortcut]).
List<WindowShortcut> windowShortcuts(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => _appleWindowShortcuts,
      _ => _otherWindowShortcuts,
    };

const List<WindowCommand> _pageCommands = [
  WindowCommand.showFiles,
  WindowCommand.showGit,
  WindowCommand.showSnippets,
  WindowCommand.showAssistant,
];

final List<WindowShortcut> _appleWindowShortcuts = [
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyS, meta: true, control: true),
    WindowCommand.toggleSidebar,
  ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyI, meta: true, alt: true),
    WindowCommand.toggleInspector,
  ),
  for (final (i, command) in _pageCommands.indexed)
    WindowShortcut._(
      SingleActivator(_tabNumberKeys[i], meta: true, alt: true),
      command,
    ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
    WindowCommand.undo,
  ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
    WindowCommand.redo,
  ),
];

final List<WindowShortcut> _otherWindowShortcuts = [
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true),
    WindowCommand.toggleSidebar,
    leftAltOnly: true,
  ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyI, control: true, alt: true),
    WindowCommand.toggleInspector,
    leftAltOnly: true,
  ),
  for (final (i, command) in _pageCommands.indexed)
    WindowShortcut._(
      SingleActivator(_tabNumberKeys[i], control: true, alt: true),
      command,
      leftAltOnly: true,
    ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    WindowCommand.undo,
  ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
    WindowCommand.redo,
  ),
  const WindowShortcut._(
    SingleActivator(LogicalKeyboardKey.keyY, control: true),
    WindowCommand.redo,
  ),
];

/// Run the window shortcut [event] is, if it is one ([windowShortcuts]).
///
/// Undo and redo are left alone, unhandled, where something else keeps a
/// history: a focused text field or the editor (which answer
/// [UndoTextIntent]), and off Apple platforms the terminal, whose Ctrl+Z
/// suspends the shell's job. ⌘ never reaches a shell, so on a Mac ⌘Z in
/// the terminal undoes the app's last change.
KeyEventResult handleWindowShortcut(
  BuildContext context,
  AppState state,
  KeyEvent event,
  ShortcutOrigin origin,
) {
  final platform = Theme.of(context).platform;
  final apple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  final historyStandsDown =
      _focusKeepsTextHistory() || (!apple && origin == ShortcutOrigin.terminal);
  return dispatchGhostChord([
    for (final shortcut in windowShortcuts(platform))
      if (!(shortcut.command.stepsHistory && historyStandsDown))
        GhostChordBinding(
          activator: shortcut.chord,
          // A held toggle would flicker the pane; a held ⌘Z steps back
          // change by change, as a Mac app's does.
          repeats: shortcut.command.stepsHistory,
          leftAltOnly: shortcut.leftAltOnly,
          onInvoke: () => runWindowCommand(context, state, shortcut.command),
        ),
  ], event);
}

/// Whether the focused widget keeps its own undo history: a text field or
/// the built-in editor, both of which answer [UndoTextIntent].
bool _focusKeepsTextHistory() {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null || !focus.mounted) return false;
  return Actions.maybeFind<UndoTextIntent>(
        focus,
        intent: const UndoTextIntent(SelectionChangedCause.keyboard),
      ) !=
      null;
}

/// Runs [command]; the toolbar's pane buttons take the same path.
void runWindowCommand(
  BuildContext context,
  AppState state,
  WindowCommand command,
) {
  switch (command) {
    case WindowCommand.toggleSidebar:
      unawaited(state.setSidebarVisible(!state.sidebarVisible));
    case WindowCommand.toggleInspector:
      unawaited(state.setInspectorVisible(!state.inspectorVisible));
    case WindowCommand.showFiles:
      unawaited(state.showInspectorPage(InspectorPage.files));
    case WindowCommand.showGit:
      unawaited(state.showInspectorPage(InspectorPage.git));
    case WindowCommand.showSnippets:
      unawaited(state.showInspectorPage(InspectorPage.snippets));
    case WindowCommand.showAssistant:
      unawaited(state.showInspectorPage(InspectorPage.assistant));
    case WindowCommand.undo || WindowCommand.redo:
      unawaited(_stepUndoHistory(context, state, command));
  }
}

/// Undo or redo the app's last change, and say which: with no menu
/// naming it, the notice is how the user learns what Ctrl+Z took back
/// ("Delete snippet undone").
Future<void> _stepUndoHistory(
  BuildContext context,
  AppState state,
  WindowCommand command,
) async {
  final history = state.undoHistory;
  final undo = command == WindowCommand.undo;
  final name = undo ? history.undoName : history.redoName;
  if (name == null) return;
  try {
    await (undo ? history.undo() : history.redo());
  } catch (error) {
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: 'Couldn’t ${undo ? 'undo' : 'redo'} “$name”: $error',
    );
    return;
  }
  if (!context.mounted) return;
  showTopToastIn(context, message: '$name ${undo ? 'undone' : 'redone'}');
}

/// Cross-platform keyboard shortcuts for the menu commands. On macOS the native
/// menu (wired in MainFlutterWindow.swift) owns ⌘T, ⌘, and ⌘K; this also covers
/// Linux/Windows, where there is no system menu bar. The native menu and these
/// shortcuts share the same Dart actions. The tab shortcuts ([tabShortcuts])
/// and the window shortcuts ([windowShortcuts]) are Dart's alone on every
/// platform: the native menu has no item for them, so ⌘W reaches here
/// instead of closing the window.
class AppMenus extends StatelessWidget {
  final Widget child;
  const AppMenus({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return CallbackShortcuts(
      bindings: {
        _ServerFilterChord(Theme.of(context).platform): () =>
            ServerListPane.revealFilter(),
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true): () =>
            openNewTab(state),
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
            openNewTab(state),
        // The terminal's own New Tab chord, so it works wherever focus is.
        const SingleActivator(
          LogicalKeyboardKey.keyT,
          control: true,
          shift: true,
        ): () =>
            openNewTab(state),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            openSettings,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            openSettings,
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          final tab = handleTabShortcut(context, state, event);
          if (tab != KeyEventResult.ignored) return tab;
          return handleWindowShortcut(
            context,
            state,
            event,
            ShortcutOrigin.window,
          );
        },
        child: child,
      ),
    );
  }
}

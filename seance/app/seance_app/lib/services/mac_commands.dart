import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app runs in the macOS runner, whose native menu bar, context
/// menus, alerts and panels this channel reaches. Widget tests run on other
/// hosts, often under a macOS theme; they keep the Flutter fallbacks.
bool get macNativeShell => !kIsWeb && Platform.isMacOS;

/// The channel the native menu bar, toolbar, Dock menu and alerts
/// (`macos/Runner/MainMenu.swift`, `MainFlutterWindow.swift`) and Dart talk
/// over, both ways.
const MethodChannel macMenuChannel = MethodChannel('seance/menu');

/// Every command the macOS menu bar, toolbar and Dock menu run. Each
/// crosses the channel as its [name], which MainMenu.swift's items carry,
/// so renaming one is a change on both sides.
enum AppCommand {
  checkForUpdates,
  settings,
  newServer,
  newTab,
  newLocalShell,
  closeTab,

  /// Closes (hides) the main window; MainMenu.swift runs it natively and
  /// asks Dart only whether it applies.
  closeWindow,
  save,
  saveLocally,
  exportText,
  importSshConfig,
  undo,
  redo,
  cut,
  copy,
  paste,
  selectAll,
  clearScrollback,
  find,
  findNext,
  findPrevious,
  useSelectionForFind,
  toggleSidebar,
  toggleInspector,
  showFiles,
  showGit,
  showSnippets,
  showAssistant,
  toggleDensity,
  actualSize,
  zoomIn,
  zoomOut,
  connectToServer,
  reconnect,
  disconnect,

  /// The toolbar's one connection button: Disconnect while the session is
  /// connected ([CommandState.checked]), Reconnect otherwise.
  connection,
  editServer,
  duplicateServer,
  togglePin,
  copySshCommand,
  deleteServer,
  generateCommand,
  previousTab,
  nextTab,
  showMainWindow,
  help,
  keyboardShortcuts,
}

/// One command as the menu shows it: whether it applies now, its checkmark
/// (null for a command that is not a toggle) and a title replacing the
/// item's own (null keeps it).
@immutable
final class CommandState {
  const CommandState({this.enabled = false, this.checked, this.title});

  static const CommandState disabled = CommandState();
  static const CommandState available = CommandState(enabled: true);

  final bool enabled;
  final bool? checked;
  final String? title;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'checked': ?checked,
    'title': ?title,
  };

  @override
  bool operator ==(Object other) =>
      other is CommandState &&
      other.enabled == enabled &&
      other.checked == checked &&
      other.title == title;

  @override
  int get hashCode => Object.hash(enabled, checked, title);

  @override
  String toString() => 'CommandState($enabled, $checked, $title)';
}

/// A server the Dock menu offers: its id and label.
typedef DockServer = ({String id, String label});

/// What the native side asks of Dart.
abstract interface class MacCommandHandler {
  /// Runs [command], chosen from the menu bar, toolbar or Dock menu.
  Future<void> runCommand(AppCommand command);

  /// Opens the server with [serverId], chosen from the Dock menu.
  Future<void> openServer(String serverId);
}

/// The Dart end of [macMenuChannel]: publishes command states, only what
/// changed since the last publish, and the window's title; hands what the
/// user chose to a [MacCommandHandler].
final class MacCommandBridge {
  MacCommandBridge({this._channel = macMenuChannel});

  final MethodChannel _channel;
  final Map<AppCommand, CommandState> _published = {};
  List<DockServer>? _publishedDock;
  (String, String)? _publishedTitle;

  /// The Dock starts with no badge; null after a failed send.
  ({String? label})? _publishedBadge = (label: null);

  /// Starts answering the native side; null stops it.
  set handler(MacCommandHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null ? null : (call) => _handle(handler, call),
    );
  }

  Future<Object?> _handle(MacCommandHandler handler, MethodCall call) async {
    switch (call.method) {
      case 'run':
        final name = call.arguments;
        final command = AppCommand.values.asNameMap()[name];
        if (command == null) {
          throw PlatformException(code: 'UNKNOWN_COMMAND', message: '$name');
        }
        await handler.runCommand(command);
      case 'openServer':
        await handler.openServer(call.arguments as String);
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  /// Sends the commands in [states] whose state changed, and the Dock's
  /// server list when it changed. A failed send forgets what it carried,
  /// so the next publish sends it again.
  Future<void> publish(
    Map<AppCommand, CommandState> states, {
    List<DockServer>? dockServers,
  }) async {
    final payload = <String, Object?>{};
    final changed = <AppCommand>[];
    for (final MapEntry(key: command, value: state) in states.entries) {
      if (_published[command] == state) continue;
      _published[command] = state;
      changed.add(command);
      payload[command.name] = state.toJson();
    }
    final dock = dockServers;
    final dockChanged = dock != null && !listEquals(dock, _publishedDock);
    if (dockChanged) {
      _publishedDock = dock;
      payload['dockServers'] = [
        for (final server in dock) [server.id, server.label],
      ];
    }
    if (payload.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('setCommandStates', payload);
    } catch (error) {
      changed.forEach(_published.remove);
      if (dockChanged) _publishedDock = null;
      debugPrint('Menu state not sent: $error');
    }
  }

  /// The Dock icon's badge: [label], or none for null.
  Future<void> setDockBadge(String? label) async {
    if (_publishedBadge == (label: label)) return;
    _publishedBadge = (label: label);
    try {
      await _channel.invokeMethod<void>('setDockBadge', label);
    } catch (error) {
      _publishedBadge = null;
      debugPrint('Dock badge not set: $error');
    }
  }

  /// The window's title and subtitle, for the Window menu, Mission Control
  /// and the Dock (the title bar hides them; the header draws its own).
  Future<void> setWindowTitle(String title, String subtitle) async {
    if (_publishedTitle == (title, subtitle)) return;
    _publishedTitle = (title, subtitle);
    try {
      await _channel.invokeMethod<void>('setWindowTitle', {
        'title': title,
        'subtitle': subtitle,
      });
    } catch (error) {
      _publishedTitle = null;
      debugPrint('Window title not sent: $error');
    }
  }
}

/// A native alert's look: [warning] for confirmations, [critical] for
/// ones that lose data.
enum MacAlertStyle { warning, critical }

/// What the user chose in a native alert: the button's index, and whether
/// they ticked its suppression box.
typedef MacAlertAnswer = ({int button, bool suppressed});

/// Shows a native alert, as a sheet on the main window while it is on
/// screen. The first of [buttons] is the default (Return); one titled
/// Cancel takes Escape. Null when the native side could not show it.
Future<MacAlertAnswer?> showMacAlert({
  required String message,
  String informative = '',
  required List<String> buttons,
  int? destructive,
  MacAlertStyle style = MacAlertStyle.warning,
  String? suppression,
  MethodChannel channel = macMenuChannel,
}) async {
  try {
    final answer = await channel.invokeMapMethod<String, Object?>('showAlert', {
      'message': message,
      'informative': informative,
      'buttons': buttons,
      'destructive': ?destructive,
      'style': style.name,
      'suppression': ?suppression,
    });
    if (answer == null) return null;
    return (
      button: answer['button'] as int? ?? -1,
      suppressed: answer['suppressed'] as bool? ?? false,
    );
  } catch (error) {
    debugPrint('Native alert failed: $error');
    return null;
  }
}

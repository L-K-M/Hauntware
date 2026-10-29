import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';

import '../../l10n/app_localizations.dart';
import 'app_commands.dart';
import 'app_menus.dart';

/// Renders the app's menus from the command registry (03 §10.2), as
/// Poltergeist's `AppMenuHost` does: on macOS the model goes to the native
/// menu bar through [PlatformMenuBar]; on Linux and Windows the same model
/// renders as a Flutter [MenuBar] strip above [child]; phones and tablets
/// get no menu at all.
///
/// On every desktop the registry's shortcuts are bound through ghost_ui's
/// [GhostChordScope] (Poltergeist's `CommandChordScope`), so a shortcut
/// runs its command as the menu row does. On macOS the same chords are the
/// native items' key equivalents: Flutter sees a key first, and only one it
/// leaves unhandled (a focused text field, which suspends the chord scope)
/// reaches the menu bar, so a press never runs a command twice.
///
/// The host owns no command behavior: labels, enablement and shortcut
/// hints come from each [AppCommand], and activation runs the command with
/// this host's context.
class AppMenuHost extends StatefulWidget {
  const AppMenuHost({
    super.key,
    required this.commands,
    required this.child,
    this.listenable,
  });

  /// The registry snapshot. Activation looks a command up here by id, so a
  /// rebuilt list with new closures is what runs.
  final List<AppCommand> commands;

  /// What can flip a command's enablement (the fleet, while an import
  /// runs); the menus are rebuilt whenever it notifies.
  final Listenable? listenable;

  final Widget child;

  @override
  State<AppMenuHost> createState() => _AppMenuHostState();
}

class _AppMenuHostState extends State<AppMenuHost> {
  /// The macOS serialization's cache: [PlatformMenuBar] re-sends the whole
  /// menu tree over the platform channel whenever its items differ, and
  /// the fleet notifies far more often than the menus change, so identical
  /// menus keep identical item objects.
  List<Object?>? _menuSignature;
  List<PlatformMenuItem>? _platformMenus;

  /// Starts with focus inside the host: the chord scope only hears keys
  /// from a focused descendant, and the route's own focus scope sits above
  /// it. It holds focus only until something focusable is chosen.
  final FocusNode _initialFocus = FocusNode(
    debugLabel: 'AppMenuHost',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addLateKeyEventHandler(_pageHistoryKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeLateKeyEventHandler(_pageHistoryKey);
    _initialFocus.dispose();
    super.dispose();
  }

  /// Page routes sit beside the home route's chord scope. History keys
  /// reach them after focused controls decline; dialogs keep their keys.
  KeyEventResult _pageHistoryKey(KeyEvent event) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null ||
        focus.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final route = ModalRoute.of(focus);
    if (route is! PageRoute || !route.isCurrent) return KeyEventResult.ignored;
    final platform = Theme.of(context).platform;
    return dispatchGhostChord([
      for (final command in widget.commands)
        if (command.id == kEditUndoCommandId ||
            command.id == kEditRedoCommandId)
          for (final activator in command.activators(platform))
            GhostChordBinding(
              activator: activator,
              repeats: command.repeats,
              onInvoke: () => _run(command.id),
            ),
    ], event);
  }

  void _run(String? id) {
    for (final command in widget.commands) {
      if (command.id != id) continue;
      if (!command.enabled()) return;
      unawaited(
        command.run(context).catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              context: ErrorDescription('while running ${command.id}'),
            ),
          );
        }),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final menuBar = switch (platform) {
      TargetPlatform.macOS => _MenuBackend.native,
      TargetPlatform.linux || TargetPlatform.windows => _MenuBackend.strip,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => null,
    };
    if (menuBar == null) return widget.child;

    final content = GhostChordScope(
      bindings: [
        for (final command in widget.commands)
          for (final activator in command.activators(platform))
            GhostChordBinding(
              activator: activator,
              repeats: command.repeats,
              leftAltOnly: command.leftAltOnly,
              onInvoke: () => _run(command.id),
            ),
      ],
      child: Focus(
        focusNode: _initialFocus,
        autofocus: true,
        child: widget.child,
      ),
    );
    final listenable = widget.listenable;
    if (listenable == null) return _menus(context, menuBar, content);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, child) => _menus(context, menuBar, child!),
      child: content,
    );
  }

  Widget _menus(BuildContext context, _MenuBackend backend, Widget content) {
    final platform = Theme.of(context).platform;
    final menus = buildAppMenus(
      commands: widget.commands,
      l10n: AppLocalizations.of(context),
      platform: platform,
    );
    switch (backend) {
      case _MenuBackend.native:
        return PlatformMenuBar(menus: _syncedMenus(menus), child: content);
      case _MenuBackend.strip:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // MenuBar shrink-wraps its children; pinned to the start edge,
            // the strip reads as a left-aligned bar.
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: MenuBar(
                children: ghostMenuBarChildren(
                  menus,
                  activate: (spec) => _run(spec.id),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: content),
          ],
        );
    }
  }

  /// Serializes [menus] once per content change; a rebuild with the same
  /// signature reuses the item objects, so the platform bar's equality
  /// check skips the channel sync.
  List<PlatformMenuItem> _syncedMenus(List<GhostMenu> menus) {
    final signature = ghostMenuSignature(menus);
    final cached = _platformMenus;
    if (cached != null && listEquals(signature, _menuSignature)) {
      return cached;
    }
    final built = ghostPlatformMenus(
      menus,
      activate: (spec, shortcut) =>
          () => _activateNative(spec.id, shortcut),
    );
    _menuSignature = signature;
    _platformMenus = built;
    return built;
  }

  /// Runs a menu item activated natively (click or key equivalent).
  ///
  /// A natively bound key equivalent reaches the menu before a focused
  /// text field sees the keystroke, so a chord a text surface owns
  /// outright (the suite's ⌘Z/⇧⌘Z, ghost_ui's `ghostEditingTextIntent`)
  /// re-dispatches the matching text intent to that field instead of
  /// running the command. When the field's handler is absent or disabled
  /// (a read-only field's Undo, say), the command runs as usual rather
  /// than the key equivalent being swallowed.
  void _activateNative(String? id, MenuSerializableShortcut? shortcut) {
    final intent = shortcut == null ? null : ghostEditingTextIntent(shortcut);
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (intent != null &&
        focusContext != null &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null) {
      final action = Actions.maybeFind(focusContext, intent: intent);
      if (action != null && action.isEnabled(intent)) {
        Actions.invoke(focusContext, intent);
        return;
      }
    }
    _run(id);
  }
}

enum _MenuBackend {
  /// The macOS menu bar, through [PlatformMenuBar].
  native,

  /// A Flutter [MenuBar] strip above the content (Linux, Windows).
  strip,
}

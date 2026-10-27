import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ghost_ui/ghost_ui.dart' show formatShortcutActivator;

import '../l10n/app_localizations.dart';
import 'menus/app_commands.dart';

/// One line of the keyboard map (PLT-06): [keys] as the user presses
/// them and what they do.
@immutable
final class KeyboardMapEntry {
  const KeyboardMapEntry(this.keys, this.action);

  final String keys;
  final String action;
}

/// The keys every window takes (03 §10.6), read from the command registry
/// so the map cannot drift from the menus: each enabled command with a
/// shortcut, and Esc, which closes the top dialog, sheet or page.
List<KeyboardMapEntry> commandKeyboardMap(
  AppLocalizations l10n,
  TargetPlatform platform,
  List<AppCommand> commands,
) => [
  for (final command in commands)
    if (command
            .activators(platform)
            .map((activator) => formatShortcutActivator(activator, platform))
            .nonNulls
            .firstOrNull
        case final keys?)
      KeyboardMapEntry(keys, command.label(l10n)),
  KeyboardMapEntry(l10n.keyboardMapEscapeKeys, l10n.keyboardMapEscape),
];

/// Hands the window's command keys to [showKeyboardMap], so a list's `?`
/// shows them under its own.
class KeyboardMapScope extends InheritedWidget {
  const KeyboardMapScope({
    super.key,
    required this.commandKeys,
    required super.child,
  });

  /// The window's command keys, read when the map opens.
  final List<KeyboardMapEntry> Function(BuildContext context) commandKeys;

  static KeyboardMapScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<KeyboardMapScope>();

  @override
  bool updateShouldNotify(KeyboardMapScope oldWidget) =>
      commandKeys != oldWidget.commandKeys;
}

/// Shows the keys in effect (PLT-06): [list]'s, the focused list's own,
/// first when given, then the window's from [KeyboardMapScope].
Future<void> showKeyboardMap(
  BuildContext context, {
  List<KeyboardMapEntry> list = const [],
}) {
  final everywhere =
      KeyboardMapScope.maybeOf(context)?.commandKeys(context) ?? const [];
  return showDialog<void>(
    context: context,
    builder: (context) {
      final l10n = AppLocalizations.of(context);
      return AlertDialog(
        title: Text(l10n.keyboardMapTitle),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (list.isNotEmpty) ...[
                  _Section(title: l10n.keyboardMapList, entries: list),
                  const SizedBox(height: 16),
                ],
                if (everywhere.isNotEmpty)
                  _Section(
                    title: l10n.keyboardMapEverywhere,
                    entries: everywhere,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.keyboardMapClose),
          ),
        ],
      );
    },
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.entries});

  final String title;
  final List<KeyboardMapEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 8),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 160,
                    child: Text(
                      entry.keys,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(child: Text(entry.action)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Esc goes back (PLT-06): over [child], the app's navigator, an Escape
/// that no list or menu closer to focus took first closes what it
/// always did (a dialog, sheet or menu that Esc dismisses) and otherwise
/// pops the page that holds focus, such as the phone's server screen or
/// the Settings page. A dialog Esc does not dismiss stays, and the home
/// page has nothing to pop.
///
/// It binds Escape to an intent of its own, since a page route's
/// disabled [DismissIntent] action would stop the search for one above
/// it, and hands the key to [DismissIntent] where that is enabled.
class EscapeGoesBack extends StatelessWidget {
  const EscapeGoesBack({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      // A held Esc goes back once, not a page per repeat.
      SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
          _EscapeIntent(),
    },
    child: Actions(actions: {_EscapeIntent: _EscapeAction()}, child: child),
  );
}

final class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

final class _EscapeAction extends ContextAction<_EscapeIntent> {
  @override
  Object? invoke(_EscapeIntent intent, [BuildContext? context]) {
    if (context == null) return null;

    const dismiss = DismissIntent();
    final action = Actions.maybeFind<DismissIntent>(context, intent: dismiss);
    if (action != null) {
      final (enabled, result) = Actions.of(
        context,
      ).invokeActionIfEnabled(action, dismiss, context);
      if (enabled) return result;
    }

    if (ModalRoute.of(context) is! PageRoute) return null;
    return Navigator.of(context).maybePop();
  }
}

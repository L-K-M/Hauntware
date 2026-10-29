import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoHistory;

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../top_toast.dart';

/// The app-data Undo command (10 §8's Edit menu): ⌘Z on macOS, Ctrl+Z
/// elsewhere.
const kEditUndoCommandId = 'edit.undo';

/// Its Redo: ⇧⌘Z on macOS, Ctrl+Shift+Z and Ctrl+Y elsewhere.
const kEditRedoCommandId = 'edit.redo';

/// Commands honor the focused control; a deletion notice targets its own
/// app-data change even while a text field keeps focus.
enum EditHistoryTarget { focusedControl, appData }

/// 10 §8's Edit ▸ Undo / Redo over the app-data [GhostUndoHistory] —
/// distinct from the selection history's `edit.undoSelection` pair below
/// them in the menu (their Alt-modified chords cannot collide with the
/// plain suite chords here). Registered unconditionally so the rows stay
/// visible-disabled while the stack is empty; once a change is recorded
/// the label names it ("Undo Delete Favorite"), the way a document
/// app's rows do.
///
/// A text surface keeps its own history while one holds focus: the chord
/// scope's field-first suspension, the native menu's Edit-verb
/// retargeting, and [stepEditHistory]'s own stand-down all keep these
/// steps out of fields and the built-in editor.
List<RegisteredCommand> buildEditHistoryCommands({
  required GhostUndoHistory history,
}) => [
  RegisteredCommand(
    id: kEditUndoCommandId,
    scope: CommandScope.app,
    label: (l10n) => switch (history.undoName) {
      null => l10n.editUndoLabel,
      final name => l10n.editUndoNamedLabel(name),
    },
    icon: Icons.undo,
    activators: _perPlatform(
      macOS: const [SingleActivator(LogicalKeyboardKey.keyZ, meta: true)],
      other: const [SingleActivator(LogicalKeyboardKey.keyZ, control: true)],
    ),
    enabled: () => history.undoName != null,
    disabledReason: (l10n) => l10n.commandDisabledNoUndo,
    run: (context) => stepEditHistory(
      Overlay.of(context, rootOverlay: true),
      history,
      direction: UndoDirection.undo,
    ),
    menuPlacement: const CommandMenuPlacement(menu: AppMenuId.edit, order: 0),
  ),
  RegisteredCommand(
    id: kEditRedoCommandId,
    scope: CommandScope.app,
    label: (l10n) => switch (history.redoName) {
      null => l10n.editRedoLabel,
      final name => l10n.editRedoNamedLabel(name),
    },
    icon: Icons.redo,
    activators: _perPlatform(
      macOS: const [
        SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
      ],
      other: const [
        SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
        SingleActivator(LogicalKeyboardKey.keyY, control: true),
      ],
    ),
    enabled: () => history.redoName != null,
    disabledReason: (l10n) => l10n.commandDisabledNoRedo,
    run: (context) => stepEditHistory(
      Overlay.of(context, rootOverlay: true),
      history,
      direction: UndoDirection.redo,
    ),
    menuPlacement: const CommandMenuPlacement(menu: AppMenuId.edit, order: 1),
  ),
];

List<ShortcutActivator> Function(TargetPlatform) _perPlatform({
  required List<ShortcutActivator> macOS,
  required List<ShortcutActivator> other,
}) =>
    (platform) => platform == TargetPlatform.macOS ? macOS : other;

/// Steps [history] once and says which way in a toast ("Delete Favorite
/// undone") — the suite chords and the menu rows share this path, and a
/// failed or declined step says why (Séance's
/// _stepUndoHistory).
///
/// A text surface keeps its own history: while the primary focus sits in
/// an [EditableText] the step forwards the text intent there instead, so
/// a menu click on Undo undoes the field's text rather than the app's
/// change — and a field that cannot take the intent swallows the step,
/// the same stand-down the native menu's retargeting applies.
Future<void> stepEditHistory(
  OverlayState overlay,
  GhostUndoHistory history, {
  required UndoDirection direction,
  EditHistoryTarget target = EditHistoryTarget.focusedControl,
}) async {
  if (!overlay.mounted) return;
  final undo = direction == UndoDirection.undo;
  final focus = FocusManager.instance.primaryFocus?.context;
  if (target == EditHistoryTarget.focusedControl &&
      focus != null &&
      focus.findAncestorWidgetOfExactType<EditableText>() != null) {
    final intent = undo
        ? const UndoTextIntent(SelectionChangedCause.keyboard)
        : const RedoTextIntent(SelectionChangedCause.keyboard);
    final action = Actions.maybeFind(focus, intent: intent);
    if (action != null && action.isEnabled(intent)) {
      Actions.invoke(focus, intent);
    }
    return;
  }
  final name = undo ? history.undoName : history.redoName;
  if (name == null) return;
  final l10n = AppLocalizations.of(overlay.context);
  try {
    await (undo ? history.undo() : history.redo());
  } catch (error) {
    if (!overlay.mounted) return;
    showTopToast(
      overlay,
      message: undo
          ? l10n.editUndoFailed(name, '$error')
          : l10n.editRedoFailed(name, '$error'),
    );
    return;
  }
  if (!overlay.mounted) return;
  showTopToast(
    overlay,
    message: undo ? l10n.editUndone(name) : l10n.editRedone(name),
  );
}

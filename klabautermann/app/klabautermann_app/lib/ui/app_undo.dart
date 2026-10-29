import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show UndoDirection;
import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoableChange, GhostUndoHistory, GhostUndoDeclined, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show SyncedRule, uuidV4;

import '../controllers/alert_rules_controller.dart';
import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import 'alert_rules.dart' show AlertRuleEdit;

/// Hands the app's [GhostUndoHistory] to the surfaces that record
/// undoable changes; without one, as in tests that leave it out, a change
/// still applies and only Undo is missed.
class UndoHistoryScope extends InheritedNotifier<GhostUndoHistory> {
  const UndoHistoryScope({
    super.key,
    required GhostUndoHistory history,
    required super.child,
  }) : super(notifier: history);

  static GhostUndoHistory? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UndoHistoryScope>()?.notifier;
}

/// Undo or redo the app's last change, and say which: with no menu
/// naming it, the notice is how the user learns what Ctrl+Z took back
/// ("Delete alert rule undone"). The `edit.undo`/`edit.redo` commands run
/// it; a delete toast's Undo action calls [GhostUndoHistory.undo]
/// directly, guarded by `isNextUndo` for its own change only.
Future<void> stepUndoHistory(
  OverlayState overlay,
  GhostUndoHistory history, {
  required UndoDirection direction,
}) async {
  final undo = direction == UndoDirection.undo;
  final l10n = AppLocalizations.of(overlay.context);
  final name = undo ? history.undoName : history.redoName;
  if (name == null) return;
  try {
    await (undo ? history.undo() : history.redo());
  } catch (error) {
    if (!overlay.mounted) return;
    showTopToast(
      overlay,
      message: undo
          ? l10n.toastUndoFailed(name, '$error')
          : l10n.toastRedoFailed(name, '$error'),
    );
    return;
  }
  if (!overlay.mounted) return;
  showTopToast(
    overlay,
    message: undo ? l10n.toastChangeUndone(name) : l10n.toastChangeRedone(name),
  );
}

/// Pins [server] to the rail's PINNED section, or unpins it, as an
/// undoable change (fleet.pin / fleet.unpin). A save failure shows the
/// pin toast the rows always did.
Future<void> pinServerUndoably(
  BuildContext context,
  FleetController fleet,
  FleetServer server,
) async {
  final l10n = AppLocalizations.of(context);
  final history = UndoHistoryScope.maybeOf(context);
  final overlay = Overlay.of(context, rootOverlay: true);
  final notSaved = l10n.fleetPinNotSaved;
  final pinning = !fleet.pinnedServerIds.contains(server.id);
  try {
    await (pinning ? fleet.pin(server.id) : fleet.unpin(server.id));
  } on Exception catch (error) {
    debugPrint('$error');
    if (overlay.mounted) showTopToast(overlay, message: notSaved);
    return;
  }
  history?.record(
    GhostUndoableChange(
      name: pinning ? l10n.changePinServer : l10n.changeUnpinServer,
      undo: () => pinning ? fleet.unpin(server.id) : fleet.pin(server.id),
      redo: () => pinning ? fleet.pin(server.id) : fleet.unpin(server.id),
    ),
  );
}

/// Deletes [synced] at once — no confirm dialog, as Finder and Notes
/// delete — and records it, returning the change so the caller's toast
/// can offer Undo while it is the one Undo would take back
/// (`history.isNextUndo`). Undo restores the same rule id and target
/// through [AlertRulesController.put].
Future<GhostUndoableChange?> deleteAlertRuleUndoably(
  BuildContext context,
  AlertRulesController rules,
  SyncedRule synced,
) async {
  final l10n = AppLocalizations.of(context);
  final history = UndoHistoryScope.maybeOf(context);
  await rules.remove(synced.id);
  if (history == null) return null;
  final change = GhostUndoableChange(
    name: l10n.changeDeleteAlertRule,
    undo: () => _ruleHistoryStep(
      () => rules.put(synced.rule, id: synced.id, target: synced.target),
    ),
    redo: () => _ruleHistoryStep(() => rules.remove(synced.id)),
  );
  history.record(change);
  return change;
}

/// Applies an alert-rule save ([AlertRulesController.put]) and records
/// it: creating a rule undoes by removing the new rule's id, editing one
/// undoes by restoring [existing]. Returns the new or edited rule's id;
/// a refused write throws as [AlertRulesController.put] does.
Future<String> putAlertRuleUndoably(
  BuildContext context,
  AlertRulesController rules,
  AlertRuleEdit edited, {
  SyncedRule? existing,
}) async {
  final l10n = AppLocalizations.of(context);
  final history = UndoHistoryScope.maybeOf(context);
  // Minting the id here lets Undo remove the rule a fresh put made.
  final id = existing?.id ?? uuidV4();
  await rules.put(edited.rule, id: id, target: edited.target);
  history?.record(switch (existing) {
    final existing? => GhostUndoableChange(
      name: l10n.changeEditAlertRule,
      undo: () => _ruleHistoryStep(
        () =>
            rules.put(existing.rule, id: existing.id, target: existing.target),
      ),
      redo: () => _ruleHistoryStep(
        () => rules.put(edited.rule, id: id, target: edited.target),
      ),
    ),
    null => GhostUndoableChange(
      name: l10n.changeNewAlertRule,
      undo: () => _ruleHistoryStep(() => rules.remove(id)),
      redo: () => _ruleHistoryStep(
        () => rules.put(edited.rule, id: id, target: edited.target),
      ),
    ),
  });
  return id;
}

/// A typed refusal guarantees nothing was written, so retain the
/// recovery snapshot for retry. A lost engine acknowledgement is unknown.
Future<void> _ruleHistoryStep(Future<void> Function() write) async {
  try {
    await write();
  } on AlertRuleNotSavedException catch (error) {
    if (error.failure == null) rethrow;
    throw GhostUndoDeclined('$error');
  }
}

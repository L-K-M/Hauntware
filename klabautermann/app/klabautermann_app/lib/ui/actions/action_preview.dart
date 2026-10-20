import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'action_entry.dart' show OperationsScope;
import 'confirm.dart';

/// Below this width the preview is a bottom sheet, as on phones (10.5).
const double _sheetBelowWidth = 600;

/// Plans and previews [intent], if an operations controller is in scope
/// and no other preview is on its way (the preview is modal). [onRun]
/// hears of the plan once it runs, and [onRefused], when given, of a
/// refusal in place of its toast. Every action entry starts here.
void startAction(
  BuildContext context,
  ActionIntent intent, {
  void Function(String planId, ActionPreview preview)? onRun,
  ValueChanged<ActionRefusalReason>? onRefused,
}) {
  final operations = OperationsScope.maybeOf(context);
  if (operations == null || operations.planning) return;
  unawaited(
    previewAndRun(
      context,
      operations,
      intent,
      onRun: onRun,
      onRefused: onRefused,
    ),
  );
}

/// Plans [intent] through [operations], shows the preview, and runs the
/// plan once the user confirms (SAF-04, SAF-05). A refused plan says why
/// in a toast; the run's progress and end come as toasts from
/// [ActionResultToasts]. [onRun] hears of the plan once it runs, as
/// JOB-08's output sheet and the editor do; [onRefused], when given,
/// hears of a refusal instead of the toast, as the editor's conflict
/// sheet does. A preview that offers another intent (STK-06's orphan
/// removal) plans that one and shows it instead. Returns once the
/// preview is closed.
Future<void> previewAndRun(
  BuildContext context,
  OperationsController operations,
  ActionIntent intent, {
  void Function(String planId, ActionPreview preview)? onRun,
  ValueChanged<ActionRefusalReason>? onRefused,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  for (ActionIntent? next = intent; next != null;) {
    final answer = await operations.plan(next);
    next = null;
    if (!context.mounted) return;

    switch (answer) {
      case PlanRefused(:final reason) when onRefused != null:
        onRefused(reason);
      case PlanRefused(:final reason):
        if (overlay.mounted) {
          showTopToast(overlay, message: l10n.actionRefused(reason.name));
        }
      case PlanReady(:final planId, :final preview):
        ActionIntent? switched;
        final confirmation = await showActionPreview(
          context,
          preview,
          onSwitch: (intent) => switched = intent,
        );
        if (switched != null) {
          next = switched;
          continue;
        }
        if (confirmation == null) return;
        operations.run(planId, confirmation);
        onRun?.call(planId, preview);
        if (overlay.mounted) {
          showTopToast(
            overlay,
            message: l10n.actionRunning(preview.targetName),
          );
        }
    }
  }
}

/// Shows [preview] as a dialog on wide windows and a bottom sheet on
/// narrow ones, and returns the user's confirmation, or null when they
/// cancelled or chose another intent, which [onSwitch] hears.
Future<ActionConfirmation?> showActionPreview(
  BuildContext context,
  ActionPreview preview, {
  ValueChanged<ActionIntent>? onSwitch,
}) {
  if (MediaQuery.sizeOf(context).width < _sheetBelowWidth) {
    return showModalBottomSheet<ActionConfirmation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ActionPreviewView(preview: preview, onSwitch: onSwitch),
        ),
      ),
    );
  }
  return showDialog<ActionConfirmation>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ActionPreviewView(preview: preview, onSwitch: onSwitch),
        ),
      ),
    ),
  );
}

/// The preview's body (03 §8.5): the target, the exact steps in the
/// monospace stack with a root badge on elevated ones (SAF-03), the
/// danger findings, the impact, protection and ownership, who runs it,
/// what it leaves on the server, and the confirmation. A detached
/// operation says it continues on the server; a redeploy lists its
/// orphans with the switch that plans their removal. It pops its route
/// with the confirmation, or with null on Cancel or a switch.
class ActionPreviewView extends StatelessWidget {
  const ActionPreviewView({super.key, required this.preview, this.onSwitch});

  final ActionPreview preview;

  /// Hears the intent the user switched to, before the route pops.
  final ValueChanged<ActionIntent>? onSwitch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final mono = textTheme.bodyMedium?.copyWith(
      fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
      fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
          .skip(1)
          .toList(growable: false),
    );
    final runner = preview.runner;
    final notes = [
      if (preview.protected case final reason?)
        l10n.actionPreviewProtected(reason.name),
      if (preview.impact case final impact?)
        l10n.actionPreviewImpact(impact.kind.name, impact.count ?? 0),
      if (preview.ownership case final ownership?)
        l10n.actionPreviewOwnership(ownership.manager),
      for (final warning in PlanWarning.values)
        if (preview.warnings.contains(warning))
          l10n.actionPreviewWarning(warning.name),
    ];
    final redeploy = switch (preview.intent) {
      final RedeployStack intent when preview.orphans.isNotEmpty => intent,
      _ => null,
    };
    final switchTo = onSwitch;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Semantics(
            header: true,
            child: Text(l10n.actionPreviewTitle, style: textTheme.titleLarge),
          ),
          Text(l10n.actionPreviewTarget(preview.targetName)),
          Semantics(
            header: true,
            child: Text(l10n.actionPreviewSteps, style: textTheme.titleSmall),
          ),
          for (final step in preview.steps)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                if (step case ShellStep(elevated: true))
                  Tooltip(
                    message: l10n.actionPreviewRootDetail,
                    child: Chip(
                      label: Text(l10n.actionPreviewRoot),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: theme.colorScheme.errorContainer,
                    ),
                  ),
                Expanded(
                  child: SelectableText(switch (step) {
                    ShellStep(:final commandLine) => commandLine,
                    ApiStep() => step.display,
                  }, style: mono),
                ),
              ],
            ),
          if (preview.danger.isNotEmpty) ...[
            Semantics(
              header: true,
              child: Text(
                l10n.actionPreviewDanger,
                style: textTheme.titleSmall,
              ),
            ),
            for (final finding in preview.danger)
              Text(
                l10n.actionPreviewFinding(
                  finding.severity.name,
                  finding.explanation,
                ),
                style: textTheme.bodyMedium?.copyWith(
                  color: finding.severity == DangerSeverity.critical
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
          ],
          if (preview.orphans.isNotEmpty) ...[
            Semantics(
              header: true,
              child: Text(
                l10n.actionPreviewOrphans,
                style: textTheme.titleSmall,
              ),
            ),
            for (final name in preview.orphans) Text(name, style: mono),
            if ((redeploy, switchTo) case (final intent?, final switchTo?))
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.actionPreviewRemoveOrphans),
                value: intent.removeOrphans,
                onChanged: (remove) {
                  switchTo(
                    RedeployStack(
                      intent.serverId,
                      project: intent.project,
                      removeOrphans: remove,
                    ),
                  );
                  Navigator.of(context).pop();
                },
              ),
          ],
          for (final note in notes) Text(note, style: textTheme.bodyMedium),
          if (preview.detached)
            Text(
              theme.platform == TargetPlatform.iOS
                  ? l10n.actionPreviewDetachedIos
                  : l10n.actionPreviewDetached,
            ),
          Text(
            runner.engine == null
                ? l10n.actionPreviewRunner(runner.identity)
                : l10n.actionPreviewRunnerEngine(
                    runner.identity,
                    runner.engine!,
                  ),
          ),
          Text(l10n.actionPreviewCredentials(runner.credentials.name)),
          if (preview.hostWrites.isNotEmpty) ...[
            Semantics(
              header: true,
              child: Text(
                l10n.actionPreviewHostWrites,
                style: textTheme.titleSmall,
              ),
            ),
            for (final row in preview.hostWrites)
              Text(l10n.actionPreviewHostWrite(row.name)),
          ],
          const Divider(),
          ActionConfirm(
            tier: preview.requiredTier,
            targetName: preview.targetName,
            onConfirm: (confirmation) =>
                Navigator.of(context).pop(confirmation),
            onCancel: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Toasts each run's end (03 §8.5): done, cancelled, or why it did not
/// finish or start, in the target's name.
class ActionResultToasts extends StatefulWidget {
  const ActionResultToasts({
    super.key,
    required this.operations,
    required this.child,
  });

  final OperationsController operations;
  final Widget child;

  @override
  State<ActionResultToasts> createState() => _ActionResultToastsState();
}

class _ActionResultToastsState extends State<ActionResultToasts> {
  StreamSubscription<(String, RunState)>? _ends;

  @override
  void initState() {
    super.initState();
    _ends = widget.operations.ends.listen(_toast);
  }

  @override
  void dispose() {
    unawaited(_ends?.cancel());
    super.dispose();
  }

  void _toast((String, RunState) end) {
    if (!mounted) return;
    final (planId, state) = end;
    final l10n = AppLocalizations.of(context);
    final target = widget.operations.targetOf(planId) ?? planId;
    final message = switch (state) {
      RunFinished(:final finished) => switch (finished.outcome) {
        ActionOutcome.succeeded when finished.operationId != null =>
          l10n.actionStartedOnServer(target),
        ActionOutcome.succeeded => l10n.actionSucceeded(target),
        ActionOutcome.cancelled => l10n.actionCancelled(target),
        ActionOutcome.failed => switch (finished.failure) {
          final failure? => l10n.actionFailed(target, failure.name),
          null => l10n.actionFailedPlain(target),
        },
      },
      RunRefused(:final reason) => l10n.actionRefused(reason.name),
      RunInProgress() => null,
    };
    if (message == null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay != null) showTopToast(overlay, message: message);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../logs/log_view.dart';
import '../logs/logs_panel_controller.dart';
import 'action_entry.dart' show OperationsScope;

/// The server header's chip for [serverId]'s detached operations (03
/// §7.17, SAF-23): how many run, or how many results wait to be seen.
/// Hidden while there is neither. Tapping it opens the operations sheet.
class DetachedOperationsChip extends StatelessWidget {
  const DetachedOperationsChip({
    super.key,
    required this.serverId,
    required this.serverName,
    required this.monitoring,
  });

  final String serverId;
  final String serverName;
  final MonitoringController monitoring;

  @override
  Widget build(BuildContext context) {
    final operations = OperationsScope.maybeOf(context);
    if (operations == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: operations,
      builder: (context, _) {
        final listed = operations.detachedOf(serverId);
        final running = listed
            .where((op) => op.state == DetachedOperationState.running)
            .length;
        final results = listed.where(_waitsToBeSeen).length;
        if (running == 0 && results == 0) return const SizedBox.shrink();

        final l10n = AppLocalizations.of(context);
        return ActionChip(
          avatar: Icon(
            running > 0 ? Icons.pending_actions : Icons.assignment_turned_in,
          ),
          label: Text(
            running > 0
                ? l10n.detachedChipRunning(running)
                : l10n.detachedChipResults(results),
          ),
          onPressed: () => showDetachedOperations(
            context,
            operations: operations,
            monitoring: monitoring,
            serverId: serverId,
            serverName: serverName,
          ),
        );
      },
    );
  }
}

/// A result the user has not acknowledged yet.
bool _waitsToBeSeen(DetachedOperation op) =>
    !op.acknowledged &&
    (op.state == DetachedOperationState.done ||
        op.state == DetachedOperationState.lost);

/// [serverId]'s detached operations in a bottom sheet, each with its
/// state, its output and, once it ended, the acknowledgement that clears
/// it. The list follows the engine while it shows.
Future<void> showDetachedOperations(
  BuildContext context, {
  required OperationsController operations,
  required MonitoringController monitoring,
  required String serverId,
  required String serverName,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => ListenableBuilder(
    listenable: operations,
    builder: (context, _) => _OperationsSheet(
      operations: operations,
      monitoring: monitoring,
      serverId: serverId,
      serverName: serverName,
    ),
  ),
);

class _OperationsSheet extends StatelessWidget {
  const _OperationsSheet({
    required this.operations,
    required this.monitoring,
    required this.serverId,
    required this.serverName,
  });

  final OperationsController operations;
  final MonitoringController monitoring;
  final String serverId;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final listed = operations.detachedOf(serverId);
    // Scrolls once the operations outgrow the sheet's height.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.detachedSheetTitle(serverName),
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (operations.detachedIncomplete(serverId))
            Text(
              l10n.detachedIncomplete,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (listed.isEmpty) Text(l10n.detachedEmpty),
          for (final op in listed)
            _OperationTile(
              key: ValueKey(op.id),
              op: op,
              onShowOutput: () => showOperationOutput(
                context,
                monitoring: monitoring,
                serverId: serverId,
                title: _nameOf(l10n, op),
                operationId: op.id,
              ),
              onAcknowledge: _waitsToBeSeen(op)
                  ? () => operations.acknowledge(serverId, op.id)
                  : null,
            ),
        ],
      ),
    );
  }
}

class _OperationTile extends StatelessWidget {
  const _OperationTile({
    super.key,
    required this.op,
    required this.onShowOutput,
    required this.onAcknowledge,
  });

  final DetachedOperation op;
  final VoidCallback onShowOutput;

  /// Null once acknowledged, or while it runs.
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final acknowledge = onAcknowledge;
    final failed = switch (op) {
      DetachedOperation(state: DetachedOperationState.lost) => true,
      // A done run without an exit status is worded as finished, so it is
      // not styled as a failure either.
      DetachedOperation(state: DetachedOperationState.done, :final exitCode?) =>
        exitCode != 0,
      _ => false,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(_nameOf(l10n, op), style: theme.textTheme.titleSmall),
            if (op.action == null)
              Text(
                l10n.detachedLaunchedElsewhere,
                style: theme.textTheme.bodySmall,
              ),
            Text(
              _stateText(context, l10n, op),
              style: failed ? TextStyle(color: theme.colorScheme.error) : null,
            ),
            if (op.acknowledged)
              Text(l10n.detachedCleanupWaits, style: theme.textTheme.bodySmall),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: onShowOutput,
                  child: Text(l10n.detachedShowOutput),
                ),
                if (acknowledge != null)
                  FilledButton.tonal(
                    onPressed: acknowledge,
                    child: Text(l10n.detachedAcknowledge),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _nameOf(AppLocalizations l10n, DetachedOperation op) {
  final action = op.action;
  final target = op.targetName;
  if (action == null || target == null) return l10n.detachedUnnamed(op.id);
  return l10n.detachedName(l10n.activityAction(action), target);
}

String _stateText(
  BuildContext context,
  AppLocalizations l10n,
  DetachedOperation op,
) => switch (op) {
  DetachedOperation(state: DetachedOperationState.running, :final startedAt?) =>
    l10n.detachedRunningSince(
      MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(startedAt.toLocal())),
    ),
  DetachedOperation(state: DetachedOperationState.running) =>
    l10n.detachedRunning,
  DetachedOperation(state: DetachedOperationState.done, exitCode: 0) =>
    l10n.detachedSucceeded,
  DetachedOperation(state: DetachedOperationState.done, :final exitCode?) =>
    l10n.detachedFailed(exitCode),
  DetachedOperation(state: DetachedOperationState.done) =>
    l10n.detachedSucceeded,
  DetachedOperation(state: DetachedOperationState.lost) => l10n.detachedLost,
  DetachedOperation(state: DetachedOperationState.unknown) =>
    l10n.detachedUnknown,
};

/// Operation [operationId]'s output on [serverId], followed live in a
/// bottom sheet, each line redacted by the engine. Closing the sheet
/// closes the follow.
Future<void> showOperationOutput(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required String title,
  required String operationId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 1,
    builder: (context, _) => _OperationOutput(
      monitoring: monitoring,
      serverId: serverId,
      title: title,
      operationId: operationId,
    ),
  ),
);

class _OperationOutput extends StatefulWidget {
  const _OperationOutput({
    required this.monitoring,
    required this.serverId,
    required this.title,
    required this.operationId,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String title;
  final String operationId;

  @override
  State<_OperationOutput> createState() => _OperationOutputState();
}

class _OperationOutputState extends State<_OperationOutput> {
  late final LogsPanelController _reading =
      LogsPanelController(
          streams: widget.monitoring.logs,
          serverId: widget.serverId,
          source: OperationLogSource(widget.operationId),
        )
        ..setLive(true)
        ..setVisible(true);

  @override
  void dispose() {
    _reading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.detachedOutputTitle(widget.title),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.detachedOutputClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(child: LogView(controller: _reading.logs)),
        ],
      ),
    );
  }
}

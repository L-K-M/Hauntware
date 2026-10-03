// Rail 5's one confirmation route. The aged notice and the explicit
// `sync.purgeTrash` command both describe an immutable selection here;
// the controller then re-lists every root before deleting it.
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_plan_controller.dart';
import '../top_toast.dart';

Future<void> confirmSyncTrashPurge(
  BuildContext context,
  SyncPlanController controller,
  SyncTrashPurgeRequest request,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _SyncTrashPurgeDialog(request: request),
  );
  if (confirmed != true || !context.mounted) return;

  final l10n = AppLocalizations.of(context);
  try {
    final outcome = await controller.purgeTrash(request);
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: outcome.cancelled
          ? l10n.syncTrashPurgeCancelled(outcome.purgedRunCount)
          : l10n.syncTrashPurgeResult(
              outcome.purgedRunCount,
              outcome.failures.length,
            ),
    );
  } on SyncTrashActiveRunException {
    if (!context.mounted) return;
    showTopToastIn(context, message: l10n.syncTrashPurgeActive);
  } on RemoteFileException catch (error) {
    if (error.kind == RemoteFileErrorKind.cancelled || !context.mounted) return;
    showTopToastIn(context, message: l10n.syncTrashPurgeFailed(error.message));
  } on Object catch (error) {
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: l10n.syncTrashPurgeFailed(error.toString()),
    );
  }
}

final class _SyncTrashPurgeDialog extends StatelessWidget {
  const _SyncTrashPurgeDialog({required this.request});

  final SyncTrashPurgeRequest request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.syncTrashPurgeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.syncTrashPurgeSummary(
              request.knownFileCount,
              request.runCount,
            ),
          ),
          if (request.unjournaledRunCount > 0) ...[
            const SizedBox(height: 8),
            Text(l10n.syncTrashUnjournaled(request.unjournaledRunCount)),
          ],
          const SizedBox(height: 12),
          Text(l10n.syncTrashPurgeScope),
          if (request.spansOtherPairs) ...[
            const SizedBox(height: 8),
            Text(l10n.syncTrashPurgeOtherPairs),
          ],
          if (request.foreignRunCount > 0) ...[
            const SizedBox(height: 8),
            Text(l10n.syncTrashPurgeForeign(request.foreignRunCount)),
          ],
          const SizedBox(height: 12),
          Text(
            l10n.syncTrashPurgeForfeit,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.syncTrashPurgeConfirm),
        ),
      ],
    );
  }
}

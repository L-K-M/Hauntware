import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'panes/pane_format.dart';

/// The quit-with-transfers warning (02 §10): quitting while the queue holds
/// live tasks interrupts the close. Restartable tasks offer Pause and Quit;
/// a set containing session-only work uses operation-neutral copy and offers
/// Cancel and Quit instead. Keeping work active or dismissing vetoes the close.
enum QuitConfirmChoice { pauseAndQuit, cancelTransfersAndQuit }

/// Which safe close choices the active task set supports. A session-only job
/// cannot be represented honestly by Pause and Quit because no restart can
/// resume it.
enum QuitTaskDisposition { pauseOrCancel, cancelOnly }

/// Shows the §10 quit confirmation. [activeTasks] is the count of
/// non-terminal tasks (paused counts); [remainingBytes] is the
/// discovered-total-minus-completed floor rendered as "remaining so
/// far" — it only grows as scans discover more, so the copy never
/// overstates what is left.
Future<QuitConfirmChoice?> showQuitConfirmDialog(
  BuildContext context, {
  required int activeTasks,
  required int remainingBytes,
  required QuitTaskDisposition disposition,
}) {
  assert(
    activeTasks > 0,
    'Quit dialog shown without live tasks (02 §10)',
  );
  return showDialog<QuitConfirmChoice>(
    context: context,
    // Scrim tap / Esc dismissal must veto the quit (02 §10); keep this
    // explicit so refactors can't silently change that contract.
    barrierDismissible: true,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      final platform = Theme.of(dialogContext).platform;
      final title = switch (disposition) {
        QuitTaskDisposition.pauseOrCancel => l10n.quitConfirmTitle,
        QuitTaskDisposition.cancelOnly => l10n.quitConfirmOperationsTitle,
      };
      final body = switch (disposition) {
        QuitTaskDisposition.pauseOrCancel =>
          remainingBytes > 0
              ? l10n.quitConfirmBodyRemaining(
                  activeTasks,
                  formatPaneSize(remainingBytes, platform: platform),
                )
              : l10n.quitConfirmBody(activeTasks),
        QuitTaskDisposition.cancelOnly =>
          remainingBytes > 0
              ? l10n.quitConfirmOperationsBodyRemaining(
                  activeTasks,
                  formatPaneSize(remainingBytes, platform: platform),
                )
              : l10n.quitConfirmOperationsBody(activeTasks),
      };
      return AlertDialog(
        key: const ValueKey('quit.dialog'),
        // The body plus the restart note must survive long
        // localizations inside short windows.
        scrollable: true,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (disposition == QuitTaskDisposition.pauseOrCancel) ...[
              const SizedBox(height: 8),
              Text(l10n.quitConfirmRestartNote),
            ],
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('quit.keepTransferring'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(switch (disposition) {
              QuitTaskDisposition.pauseOrCancel => l10n.quitKeepTransferring,
              QuitTaskDisposition.cancelOnly => l10n.quitKeepWorking,
            }),
          ),
          switch (disposition) {
            QuitTaskDisposition.pauseOrCancel => TextButton(
              key: const ValueKey('quit.cancelTransfers'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(QuitConfirmChoice.cancelTransfersAndQuit),
              child: Text(l10n.quitCancelTransfersAndQuit),
            ),
            QuitTaskDisposition.cancelOnly => FilledButton(
              key: const ValueKey('quit.cancelTransfers'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(QuitConfirmChoice.cancelTransfersAndQuit),
              child: Text(l10n.quitCancelOperationsAndQuit),
            ),
          },
          if (disposition == QuitTaskDisposition.pauseOrCancel)
            FilledButton(
              key: const ValueKey('quit.pauseAndQuit'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(QuitConfirmChoice.pauseAndQuit),
              child: Text(l10n.quitPauseAndQuit),
            ),
        ],
      );
    },
  );
}

/// The close-path flush failure warning (07 §3.5): the journal did not
/// finish writing, so the window stayed open rather than destroying
/// itself over an unflushed queue. Renders the failure inside
/// ARB-authored copy — the raw error is machine data, not authored UI
/// text.
///
/// Answers true for Quit Anyway. A write that keeps failing (a full
/// disk, a wedged writer) would otherwise veto every quit, leaving only
/// killing the process. Quitting anyway loses nothing more than that,
/// since the journal is crash-consistent. Dismiss, or a dismissed
/// dialog, keeps the window open.
Future<bool> showQuitFlushFailedDialog(
  BuildContext context, {
  required String error,
}) async {
  final quit = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      return AlertDialog(
        key: const ValueKey('quitFlush.dialog'),
        scrollable: true,
        title: Text(l10n.quitFlushFailedTitle),
        content: Text(l10n.quitFlushFailedBody(error)),
        // The safe action first, as the quit confirmation orders
        // Keep Transferring: traversal reaches it before the way out.
        actions: [
          TextButton(
            key: const ValueKey('quitFlush.dismiss'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.quitFlushFailedDismiss),
          ),
          TextButton(
            key: const ValueKey('quitFlush.quitAnyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.quitFlushFailedQuitAnyway),
          ),
        ],
      );
    },
  );
  return quit ?? false;
}

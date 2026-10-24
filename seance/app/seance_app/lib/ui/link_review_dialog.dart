import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../services/link_intake.dart';
import 'top_toast.dart';

/// The trust review every `seance://connect` link passes before anything
/// connects (docs/design/suite-links.md section 6).
///
/// The server's label and endpoint come from Séance's saved record, never
/// from the link; the only link text shown is the starting folder, with
/// hidden characters removed and said so.
class SeanceLinkReviewDialog extends StatelessWidget {
  const SeanceLinkReviewDialog({super.key, required this.review});

  final SeanceLinkReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SeanceLinkQueue>(
      valueListenable: review.queue,
      builder: (context, queue, _) {
        // Every frame, so the decision covers exactly what was on screen.
        review.markShown(queue);
        return _build(context, theme, queue);
      },
    );
  }

  Widget _build(BuildContext context, ThemeData theme, SeanceLinkQueue queue) {
    final target = review.target;
    final server = target.server;
    final cwd = target.cwd;
    final folder = cwd == null ? null : safeDeepLinkDisplay(cwd);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final unnamed = queue.waitingLabels.where((label) => label == null);
    return AlertDialog(
      title: const Text('Open a terminal from a link?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(server.label, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text('${server.username}@${server.host}:${server.port}'),
            if (folder != null) ...[
              const SizedBox(height: 12),
              const Text('Starting folder'),
              const SizedBox(height: 2),
              SelectableText(folder.text),
              if (folder.removedControls) ...[
                const SizedBox(height: 4),
                Text(
                  'Hidden characters were removed from this folder name.',
                  style: muted,
                ),
              ],
            ],
            const SizedBox(height: 12),
            Text(
              cwd == null
                  ? 'Links cannot run commands.'
                  : 'Links cannot run commands. Séance types the cd command '
                        'at the prompt and does not press Enter.',
              style: muted,
            ),
            if (queue.waitingCount > 0) ...[
              const SizedBox(height: 12),
              Text(_waiting(queue.waitingCount)),
              for (final label in queue.waitingLabels)
                if (label != null) Text('• $label', style: muted),
              if (unnamed.isNotEmpty)
                Text(
                  unnamed.length == 1
                      ? '• A link Séance cannot open'
                      : '• ${unnamed.length} links Séance cannot open',
                  style: muted,
                ),
            ],
            if (queue.ignoredCount > 0) ...[
              const SizedBox(height: 12),
              Text(_ignored(queue.ignoredCount), style: muted),
            ],
          ],
        ),
      ),
      actions: [
        if (queue.waitingCount > 0)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, SeanceLinkDecision.discardWaiting),
            child: const Text('Discard waiting links'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, SeanceLinkDecision.cancel),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, SeanceLinkDecision.connect),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

String _waiting(int count) =>
    count == 1 ? '1 more link is waiting.' : '$count more links are waiting.';

String _ignored(int count) =>
    count == 1 ? '1 more link was ignored.' : '$count more links were ignored.';

/// The words for a notice; public so a test can assert each one.
String seanceLinkNoticeMessage(SeanceLinkNotice notice) =>
    switch (notice.kind) {
      SeanceLinkNoticeKind.notSeanceLink => 'This link is not a Séance link.',
      SeanceLinkNoticeKind.unacceptedParameters =>
        'This link has parameters Séance does not accept.',
      SeanceLinkNoticeKind.invalidFolder =>
        'The starting folder in this link is not valid.',
      SeanceLinkNoticeKind.unknownServer =>
        'This link names a server Séance does not have.',
      SeanceLinkNoticeKind.ambiguousServer =>
        'Several saved servers match this link.',
      SeanceLinkNoticeKind.ignoredLinks => _ignored(notice.count),
    };

/// Why a link's starting folder was not staged, worded like Files'
/// "Open terminal here".
String seanceLinkFolderMessage(SeanceLinkFolderOutcome outcome) =>
    switch (outcome) {
      SeanceLinkFolderOutcome.staged =>
        'Inserted into the prompt. Press Enter in the terminal to run.',
      SeanceLinkFolderOutcome.ended =>
        'The connection ended before the starting folder could be inserted.',
      SeanceLinkFolderOutcome.shellIntegrationRequired =>
        'Shell integration is required to insert the starting folder. '
            'Copy the path instead.',
      SeanceLinkFolderOutcome.promptNotReady =>
        'The shell prompt was not ready for the starting folder. '
            'Copy the path instead.',
      SeanceLinkFolderOutcome.pendingInput =>
        'The terminal already had input, so the starting folder was not '
            'inserted. Copy the path instead.',
    };

/// [SeanceLinkHandler] on the running app: dialogs and toasts on the root
/// navigator, connects through [AppState].
final class SeanceAppLinkHandler implements SeanceLinkHandler {
  SeanceAppLinkHandler(this._state, this._navigatorKey);

  final AppState _state;
  final GlobalKey<NavigatorState> _navigatorKey;

  @override
  List<ServerConfig> get servers => _state.servers;

  @override
  Future<SeanceLinkDecision> review(SeanceLinkReview review) async {
    final decision = await showDialog<SeanceLinkDecision>(
      context: _context(),
      builder: (context) => SeanceLinkReviewDialog(review: review),
    );
    return decision ?? SeanceLinkDecision.cancel;
  }

  @override
  Future<void> connect(SeanceLinkTarget target) async {
    final cwd = target.cwd;
    if (cwd == null) {
      // The server row's focus-or-connect.
      await _state.openTerminal(target.server);
      return;
    }
    // A fresh tab, so the cd lands at a new prompt and never in a tab
    // with input pending.
    final tab = _state.openTerminalTab(target.server);
    final outcome = await stageLinkFolder(
      engine: tab.engine,
      status: () => identical(_state.tabById(tab.id), tab) ? tab.status : null,
      changes: _state,
      folder: cwd,
    );
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final message = seanceLinkFolderMessage(outcome);
    if (outcome == SeanceLinkFolderOutcome.staged) {
      showTopToast(overlay, message: message);
      return;
    }
    showTopToast(
      overlay,
      message: message,
      actionLabel: 'Copy path',
      onAction: () => Clipboard.setData(ClipboardData(text: cwd)),
    );
  }

  @override
  Future<void> showNotice(SeanceLinkNotice notice) async {
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) {
      throw StateError('No window to show a link notice in.');
    }
    showTopToast(overlay, message: seanceLinkNoticeMessage(notice));
  }

  /// Throws while no window exists, so the intake keeps the link.
  BuildContext _context() {
    final context = _navigatorKey.currentContext;
    if (context == null) {
      throw StateError('No window to review a link in.');
    }
    return context;
  }
}

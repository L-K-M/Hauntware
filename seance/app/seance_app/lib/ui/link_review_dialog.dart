import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../services/link_intake.dart';
import 'top_toast.dart';

/// How long the review's buttons stay disabled after it opens, so a click
/// or key press meant for the window underneath cannot answer a link that
/// arrived mid-gesture. Poltergeist's review uses the same delay.
const Duration seanceLinkReviewArmDelay = Duration(milliseconds: 750);

const double _overflowRowHeight = 28;
const int _overflowVisibleRowLimit = 5;

/// The trust review every `seance://connect` link passes before anything
/// connects (docs/design/suite-links.md section 6).
///
/// The server's label and endpoint come from Séance's saved record, never
/// from the link; the only link text shown is the starting folder, with
/// hidden characters removed and said so. The waiting links follow the
/// queue while the review is open.
class SeanceLinkReviewDialog extends StatefulWidget {
  const SeanceLinkReviewDialog({super.key, required this.review});

  final SeanceLinkReview review;

  @override
  State<SeanceLinkReviewDialog> createState() => _SeanceLinkReviewDialogState();
}

class _SeanceLinkReviewDialogState extends State<SeanceLinkReviewDialog> {
  late LinkReviewSnapshot<SeanceConnectRequest> _snapshot;
  StreamSubscription<LinkReviewSnapshot<SeanceConnectRequest>>? _updates;
  Timer? _armTimer;
  bool _armed = false;

  /// Discarding links the user has not seen needs the hidden list opened
  /// first, and again whenever it grows.
  bool _overflowReviewed = false;
  int _overflowRevision = 0;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.review.link.snapshot;
    _updates = widget.review.link.snapshots.listen(_update);
    _armTimer = Timer(seanceLinkReviewArmDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    unawaited(_updates?.cancel());
    super.dispose();
  }

  void _update(LinkReviewSnapshot<SeanceConnectRequest> snapshot) {
    setState(() {
      if (snapshot.overflow.length > _snapshot.overflow.length) {
        _overflowReviewed = false;
        _overflowRevision++;
      }
      _snapshot = snapshot;
    });
  }

  void _decide(LinkReviewDecision decision) {
    // The snapshot on screen when the decision was made, not one a later
    // frame may draw while the dialog animates out.
    widget.review.link.markShown(_snapshot);
    Navigator.pop(context, decision);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final review = widget.review;
    final snapshot = _snapshot;
    final server = review.target.server;
    final cwd = review.target.cwd;
    final folder = cwd == null ? null : safeDeepLinkDisplay(cwd);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final overflowCount = snapshot.overflow.length;
    final overflowRows = overflowCount < _overflowVisibleRowLimit
        ? overflowCount
        : _overflowVisibleRowLimit;
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
            if (snapshot.remainingCount > 0) ...[
              const SizedBox(height: 12),
              Text(_waiting(snapshot.remainingCount)),
              for (final request in snapshot.visibleWaiting)
                Text('• ${_label(request)}', style: muted),
            ],
            if (overflowCount > 0)
              ExpansionTile(
                key: ValueKey('seanceLink.overflow.$_overflowRevision'),
                onExpansionChanged: (expanded) {
                  if (expanded && !_overflowReviewed) {
                    setState(() => _overflowReviewed = true);
                  }
                },
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsetsDirectional.only(start: 12),
                title: Text(_others(overflowCount)),
                children: [
                  SizedBox(
                    height: _overflowRowHeight * overflowRows,
                    width: double.maxFinite,
                    child: ListView.builder(
                      itemCount: overflowCount,
                      itemExtent: _overflowRowHeight,
                      itemBuilder: (context, index) => Text(
                        '• ${_label(snapshot.overflow[index])}',
                        style: muted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            if (snapshot.ignoredCount > 0) ...[
              const SizedBox(height: 12),
              Text(_ignored(snapshot.ignoredCount), style: muted),
            ],
          ],
        ),
      ),
      actions: [
        if (snapshot.remainingCount > 0)
          TextButton(
            onPressed: _armed && (overflowCount == 0 || _overflowReviewed)
                ? () => _decide(LinkReviewDecision.discardAllRemaining)
                : null,
            child: const Text('Discard waiting links'),
          ),
        TextButton(
          onPressed: _armed ? () => _decide(LinkReviewDecision.cancel) : null,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _armed ? () => _decide(LinkReviewDecision.connect) : null,
          child: const Text('Connect'),
        ),
      ],
    );
  }

  String _label(SeanceConnectRequest request) =>
      widget.review.labelOf(request) ?? 'A link Séance cannot open';
}

String _waiting(int count) =>
    count == 1 ? '1 more link is waiting.' : '$count more links are waiting.';

String _others(int count) =>
    count == 1 ? 'And 1 more link' : 'And $count more links';

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

/// Shows [review] on the root navigator until it is decided or its link
/// is cancelled. Only a button answers it: the barrier and Escape do not,
/// as in Poltergeist's review.
Future<LinkReviewDecision> showSeanceLinkReviewDialog(
  BuildContext context,
  SeanceLinkReview review,
) async {
  final operation = review.link;
  if (operation.isCancelled) return LinkReviewDecision.cancel;

  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<LinkReviewDecision>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        PopScope(canPop: false, child: SeanceLinkReviewDialog(review: review)),
  );
  final decision = navigator.push(route);
  // Another handler took the queue, or the app is closing: the link goes
  // back to the queue and the dialog closes unanswered.
  unawaited(
    operation.cancelled.then((_) {
      if (route.isActive) navigator.removeRoute(route);
    }),
  );
  return await decision ?? LinkReviewDecision.cancel;
}

/// [SeanceLinkHost] on the running app: dialogs and toasts on the root
/// navigator, connects through [AppState].
final class SeanceAppLinkHost implements SeanceLinkHost {
  SeanceAppLinkHost(this._state, this._navigatorKey);

  final AppState _state;
  final GlobalKey<NavigatorState> _navigatorKey;

  @override
  List<ServerConfig> get servers => _state.servers;

  @override
  Future<LinkReviewDecision> review(SeanceLinkReview review) =>
      showSeanceLinkReviewDialog(_context(), review);

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

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/deep_links.dart';

const _dialogWidth = 520.0;
const _fieldSpacing = 10.0;
const _overflowRowHeight = 32.0;
const _overflowVisibleRowLimit = 5;
const _reviewActionArmDelay = Duration(milliseconds: 750);
final _neverCancelled = Completer<void>().future;

enum _BarrierDismissal { allowed, blocked }

Future<DeepLinkReviewDecision> showDeepLinkReviewDialog(
  BuildContext context,
  DeepLinkReview review,
) async {
  final decision = await _showCancellableDialog<DeepLinkReviewDecision>(
    context: context,
    operation: review,
    barrierDismissal: _BarrierDismissal.blocked,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: ValueListenableBuilder<DeepLinkReviewSnapshot>(
        valueListenable: review,
        builder: (context, snapshot, _) =>
            _DeepLinkReviewDialog(review: review, snapshot: snapshot),
      ),
    ),
  );
  return decision ?? DeepLinkReviewDecision.cancel;
}

Future<void> showDeepLinkFailureDialog(
  BuildContext context,
  DeepLinkFailure failure, {
  DeepLinkOperation operation = const _NeverCancelledDeepLinkOperation(),
}) => _showCancellableDialog<void>(
  context: context,
  operation: operation,
  builder: (dialogContext) {
    final l10n = AppLocalizations.of(dialogContext);
    return AlertDialog(
      key: const ValueKey('deepLink.failure'),
      title: Text(l10n.deepLinkFailureTitle),
      content: Text(_failureMessage(l10n, failure.kind)),
      actions: [
        TextButton(
          key: const ValueKey('deepLink.failure.close'),
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.deepLinkFailureClose),
        ),
      ],
    );
  },
);

Future<T?> _showCancellableDialog<T>({
  required BuildContext context,
  required DeepLinkOperation operation,
  required WidgetBuilder builder,
  _BarrierDismissal barrierDismissal = _BarrierDismissal.allowed,
}) {
  if (operation.isCancelled) return Future<T?>.value();

  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissal == _BarrierDismissal.allowed,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );
  final result = navigator.push(route);
  unawaited(
    operation.cancelled.then((_) {
      if (route.isActive) navigator.removeRoute(route);
    }),
  );
  return result;
}

final class _NeverCancelledDeepLinkOperation implements DeepLinkOperation {
  const _NeverCancelledDeepLinkOperation();

  @override
  Future<void> get cancelled => _neverCancelled;

  @override
  bool get isCancelled => false;
}

String _failureMessage(AppLocalizations l10n, DeepLinkFailureKind kind) =>
    switch (kind) {
      DeepLinkFailureKind.unsupportedLink => l10n.deepLinkFailureUnsupported,
      DeepLinkFailureKind.invalidParameters => l10n.deepLinkFailureParameters,
      DeepLinkFailureKind.invalidPort => l10n.deepLinkFailurePort,
      DeepLinkFailureKind.invalidPath => l10n.deepLinkFailurePath,
      DeepLinkFailureKind.serverNotFound => l10n.deepLinkFailureServer,
    };

final class _DeepLinkReviewDialog extends StatefulWidget {
  const _DeepLinkReviewDialog({required this.review, required this.snapshot});

  final DeepLinkReview review;
  final DeepLinkReviewSnapshot snapshot;

  @override
  State<_DeepLinkReviewDialog> createState() => _DeepLinkReviewDialogState();
}

final class _DeepLinkReviewDialogState extends State<_DeepLinkReviewDialog> {
  Timer? _armTimer;
  bool _actionsArmed = false;
  bool _overflowReviewed = false;
  int _overflowRevision = 0;

  @override
  void initState() {
    super.initState();
    _armTimer = Timer(_reviewActionArmDelay, () {
      if (mounted) setState(() => _actionsArmed = true);
    });
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_DeepLinkReviewDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.snapshot.overflow.length <= oldWidget.snapshot.overflow.length) {
      return;
    }

    // New hidden endpoints require another deliberate expansion.
    _overflowReviewed = false;
    _overflowRevision++;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = widget.snapshot;
    final current = snapshot.current;
    final host = safeDeepLinkHostDisplay(current.host);
    final username = safeDeepLinkDisplay(current.username);
    final path = safeDeepLinkDisplay(current.remotePath);
    final controlsRemoved =
        host.removedControls ||
        username.removedControls ||
        path.removedControls;
    final pending = snapshot.remainingCount;
    final overflowCount = snapshot.overflow.length;
    final overflowVisibleRows = overflowCount < _overflowVisibleRowLimit
        ? overflowCount
        : _overflowVisibleRowLimit;

    return AlertDialog(
      key: const ValueKey('deepLink.review'),
      title: Text(l10n.deepLinkReviewTitle),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.deepLinkReviewBody),
              const SizedBox(height: 16),
              _EndpointDetails(
                host: host.text,
                port: current.port,
                username: username.text,
                path: path.text,
              ),
              if (current.activationCount > 1) ...[
                const SizedBox(height: _fieldSpacing),
                Text(l10n.deepLinkRepeatedActivations(current.activationCount)),
              ],
              if (host.internationalized)
                _Warning(text: l10n.deepLinkInternationalizedWarning),
              if (host.mixedScripts)
                _Warning(text: l10n.deepLinkMixedScriptWarning),
              if (host.unrecognizedScripts)
                _Warning(text: l10n.deepLinkUnrecognizedScriptWarning),
              if (controlsRemoved)
                _Warning(text: l10n.deepLinkControlsRemovedWarning),
              if (snapshot.visibleWaiting.isNotEmpty) ...[
                const Divider(height: 28),
                Text(
                  l10n.deepLinkWaitingTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                for (final link in snapshot.visibleWaiting)
                  _PendingEndpoint(link: link),
              ],
              if (overflowCount > 0)
                KeyedSubtree(
                  key: const ValueKey('deepLink.overflow'),
                  child: ExpansionTile(
                    key: ValueKey(_overflowRevision),
                    onExpansionChanged: (expanded) {
                      if (expanded && !_overflowReviewed) {
                        setState(() => _overflowReviewed = true);
                      }
                    },
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsetsDirectional.only(
                      start: 12,
                    ),
                    title: Text(l10n.deepLinkAdditionalPending(overflowCount)),
                    children: [
                      SizedBox(
                        height: _overflowRowHeight * overflowVisibleRows,
                        child: ListView.builder(
                          itemCount: overflowCount,
                          itemExtent: _overflowRowHeight,
                          itemBuilder: (context, index) => _PendingEndpoint(
                            link: snapshot.overflow.elementAt(index),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('deepLink.cancel'),
          onPressed: _actionsArmed
              ? () => Navigator.pop(context, DeepLinkReviewDecision.cancel)
              : null,
          child: Text(l10n.deepLinkCancel),
        ),
        if (pending > 0)
          TextButton(
            key: const ValueKey('deepLink.discardAll'),
            onPressed:
                _actionsArmed && (overflowCount == 0 || _overflowReviewed)
                ? () {
                    widget.review.markRemainingReviewed(snapshot);
                    Navigator.pop(
                      context,
                      DeepLinkReviewDecision.discardAllRemaining,
                    );
                  }
                : null,
            child: Text(l10n.deepLinkDiscardAll),
          ),
        FilledButton(
          key: const ValueKey('deepLink.connect'),
          onPressed: _actionsArmed
              ? () => Navigator.pop(context, DeepLinkReviewDecision.connect)
              : null,
          child: Text(l10n.deepLinkConnect),
        ),
      ],
    );
  }
}

final class _EndpointDetails extends StatelessWidget {
  const _EndpointDetails({
    required this.host,
    required this.port,
    required this.username,
    required this.path,
  });

  final String host;
  final int port;
  final String username;
  final String path;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _DetailRow(label: l10n.deepLinkHostLabel, value: host),
            _DetailRow(label: l10n.deepLinkPortLabel, value: '$port'),
            _DetailRow(
              label: l10n.deepLinkUsernameLabel,
              value: username.isEmpty ? l10n.deepLinkEmptyValue : username,
            ),
            _DetailRow(label: l10n.deepLinkFolderLabel, value: path),
          ],
        ),
      ),
    );
  }
}

final class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

final class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: _fieldSpacing),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

final class _PendingEndpoint extends StatelessWidget {
  const _PendingEndpoint({required this.link});

  final HostDeepLink link;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final host = safeDeepLinkHostDisplay(link.host).text;
    final username = safeDeepLinkDisplay(link.username).text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        l10n.deepLinkEndpointSummary(username, host, link.port),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

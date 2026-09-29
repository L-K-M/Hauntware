import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../family_hues.dart';
import 'top_toast.dart';

/// Above the server list while proposals wait: how many, and a way in.
class InboxBanner extends StatelessWidget {
  const InboxBanner({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final count = state.inboxPending.length;
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: const ValueKey('inbox.banner'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => showInbox(context, state),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.move_to_inbox,
                  size: 16,
                  color: FamilyPalette.of(context).glyph(FamilyHue.yellow),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    count == 1
                        ? '1 proposed command'
                        : '$count proposed commands',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
                Text(
                  'Review',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showInbox(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      builder: (_) => _InboxDialog(state: state),
    );

/// The list of pending proposals, and one proposal's review.
class _InboxDialog extends StatefulWidget {
  const _InboxDialog({required this.state});

  final AppState state;

  @override
  State<_InboxDialog> createState() => _InboxDialogState();
}

class _InboxDialogState extends State<_InboxDialog> {
  /// The proposal under review, by item id: the list object is replaced on
  /// every refresh.
  String? _open;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final pending = widget.state.inboxPending;
        final open = pending
            .where((p) => p.cached.itemId == _open)
            .firstOrNull;
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
            child: open == null
                ? _list(context, pending)
                : ProposalReview(
                    key: ValueKey(open.cached.itemId),
                    state: widget.state,
                    pending: open,
                    onBack: () => setState(() => _open = null),
                  ),
          ),
        );
      },
    );
  }

  Widget _list(BuildContext context, List<PendingProposal> pending) {
    final theme = Theme.of(context);
    final error = widget.state.inboxError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text('Proposed commands', style: theme.textTheme.titleMedium),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Check for new proposals',
                icon: const Icon(Icons.refresh),
                onPressed: () => widget.state.refreshInbox(),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              error,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (pending.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nothing is waiting.', textAlign: TextAlign.center),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in pending)
                  ListTile(
                    key: ValueKey('inbox.item.${p.cached.itemId}'),
                    leading: const Icon(Icons.terminal),
                    title: Text(p.proposal.title),
                    subtitle: Text(
                      '${p.app.name} · for ${p.proposal.host} · '
                      '${_age(p.proposal.created)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _open = p.cached.itemId),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

String _age(int createdSeconds) {
  final age = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(createdSeconds * 1000),
  );
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// One proposal, everything the user needs to decide: where it would run,
/// why, the whole script with nothing hidden, and what the danger linter
/// thinks of each line.
class ProposalReview extends StatefulWidget {
  const ProposalReview({
    super.key,
    required this.state,
    required this.pending,
    required this.onBack,
  });

  final AppState state;
  final PendingProposal pending;
  final VoidCallback onBack;

  @override
  State<ProposalReview> createState() => _ProposalReviewState();
}

class _ProposalReviewState extends State<ProposalReview> {
  bool _busy = false;

  InboxProposal get _proposal => widget.pending.proposal;

  Future<void> _run(ServerConfig server) async {
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    try {
      final result = await widget.state.runProposal(widget.pending, server);
      if (!mounted) return;
      if (result.ok) {
        navigator.pop();
        showTopToast(
          overlay,
          message: 'Placed in the prompt on ${server.label}. Press Enter to '
              'run it.',
        );
      } else {
        showTopToast(overlay, message: result.error!);
      }
    } catch (e) {
      if (mounted) showTopToast(overlay, message: 'Could not run: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss() async {
    setState(() => _busy = true);
    final overlay = Overlay.of(context, rootOverlay: true);
    try {
      await widget.state.dismissProposal(widget.pending);
      if (mounted) widget.onBack();
    } catch (e) {
      if (mounted) showTopToast(overlay, message: 'Could not dismiss: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _problem(InboxTargetProblem problem, String host) =>
      switch (problem) {
        InboxTargetProblem.noMatch =>
          'No server is named "$host". It can be read but not run.',
        InboxTargetProblem.ambiguous =>
          'More than one server matches "$host". Séance does not guess, so '
              'it can be read but not run.',
        InboxTargetProblem.notAllowed =>
          'This app may not target "$host". Change that in Settings > '
              'Inbox if you want to allow it.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final target = resolveInboxTarget(
      _proposal.host,
      widget.pending.app,
      widget.state.servers,
    );
    final expired = _proposal.isExpiredAt(DateTime.now());
    final revealed = revealInvisibles(_proposal.script);
    final findings = <(int, DangerFinding)>[
      for (final (i, line) in _proposal.script.split('\n').indexed)
        for (final finding in DangerLinter.scan(line)) (i + 1, finding),
    ];
    final critical = findings.any(
      (f) => f.$2.severity == DangerSeverity.critical,
    );
    final server = target.server;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack,
          ),
          title: Text(_proposal.title),
          subtitle: Text(
            'From ${widget.pending.app.name} · ${_age(_proposal.created)}',
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _Row(
                icon: Icons.dns_outlined,
                text: server != null
                    ? 'Runs on ${server.label} (${server.username}@'
                          '${server.host})'
                    : _problem(target.problem!, _proposal.host),
                color: server == null ? scheme.error : null,
              ),
              if (expired)
                _Row(
                  icon: Icons.timer_off_outlined,
                  text: 'This proposal has expired and cannot be run.',
                  color: scheme.error,
                ),
              if (_proposal.reason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Reason', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                // Plain text: never rendered as markup or links.
                SelectableText(_proposal.reason),
              ],
              const SizedBox(height: 12),
              Text('Script', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              if (revealed.hasHidden)
                _Row(
                  icon: Icons.visibility_outlined,
                  text: 'The script contains ${revealed.hiddenCount} '
                      'invisible or control character'
                      '${revealed.hiddenCount == 1 ? '' : 's'}, shown as '
                      '<U+…>. Be suspicious of a script that needs them.',
                  color: scheme.error,
                ),
              Container(
                key: const ValueKey('inbox.script'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                  border: critical ? Border.all(color: scheme.error) : null,
                ),
                child: SelectableText(
                  revealed.text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              for (final (line, finding) in findings)
                _Row(
                  icon: Icons.warning_amber_rounded,
                  text: 'Line $line: ${finding.explanation}',
                  color: finding.severity == DangerSeverity.critical
                      ? scheme.error
                      : null,
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: _proposal.script),
                      ),
                child: const Text('Copy script'),
              ),
              OutlinedButton(
                key: const ValueKey('inbox.dismiss'),
                onPressed: _busy ? null : _dismiss,
                child: const Text('Dismiss'),
              ),
              FilledButton.icon(
                key: const ValueKey('inbox.run'),
                onPressed: _busy || server == null || expired
                    ? null
                    : () => _run(server),
                icon: const Icon(Icons.keyboard_return),
                label: Text(
                  server == null ? 'Run' : 'Stage on ${server.label}',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    ),
  );
}

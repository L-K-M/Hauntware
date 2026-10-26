import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'containers_panel.dart' show DockerNotice;

/// DKE-06's security review and DKE-07's log rotation lint: on request,
/// each container's configuration read on [serverId] and what it puts at
/// risk, containers with the most severe findings first. A review reads
/// one inspect per container, so it runs only when asked and its answer
/// stays until the next one; another server starts over.
class ReviewPanel extends StatefulWidget {
  const ReviewPanel({super.key, required this.docker, required this.serverId});

  final DockerController docker;
  final String serverId;

  @override
  State<ReviewPanel> createState() => _ReviewPanelState();
}

enum _Phase { idle, reading, done }

class _ReviewPanelState extends State<ReviewPanel> {
  _Phase _phase = _Phase.idle;
  DockerPayload? _answer;

  /// Counts reviews, so only the latest answer shows.
  int _reads = 0;

  @override
  void didUpdateWidget(ReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.docker == widget.docker) {
      return;
    }

    _reads++;
    _phase = _Phase.idle;
    _answer = null;
  }

  Future<void> _review() async {
    final read = ++_reads;
    setState(() => _phase = _Phase.reading);
    final answer = await widget.docker.reviewContainers(widget.serverId);
    if (!mounted || read != _reads) return;

    setState(() {
      _phase = _Phase.done;
      _answer = answer;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final run = FilledButton.tonalIcon(
      onPressed: _phase == _Phase.reading ? null : () => unawaited(_review()),
      icon: const Icon(Icons.policy_outlined),
      label: Text(
        _phase == _Phase.idle ? l10n.dockerReviewRun : l10n.dockerReviewAgain,
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Text(
          l10n.dockerReviewIntro,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Align(alignment: AlignmentDirectional.centerStart, child: run),
        const SizedBox(height: 16),
        ..._body(context, l10n),
      ],
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    if (_phase == _Phase.idle) return const [];
    if (_phase == _Phase.reading) {
      return [
        DockerNotice(
          icon: Icons.hourglass_empty,
          text: l10n.dockerReviewReading,
        ),
      ];
    }

    switch (_answer) {
      case DockerReviewPayload(:final reviews, :final omitted):
        final flagged = [
          for (final review in reviews)
            if (review.findings.isNotEmpty) review,
        ]..sort(_byWorst);
        return [
          if (flagged.isEmpty)
            DockerNotice(
              icon: Icons.verified_user_outlined,
              text: l10n.dockerReviewNone(reviews.length),
            )
          else
            Text(
              l10n.dockerReviewFlagged(flagged.length, reviews.length),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          if (omitted > 0) ...[
            const SizedBox(height: 8),
            DockerNotice(
              icon: Icons.info_outline,
              text: l10n.dockerReviewOmitted(omitted, kDockerReviewMax),
            ),
          ],
          for (final review in flagged) ...[
            const SizedBox(height: 12),
            ContainerReviewCard(review: review),
          ],
        ];
      case DockerQueryFailed(:final failure, :final detail):
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerReviewFailed(failure.name),
            detail: detail,
          ),
        ];
      case _:
        // No other payload answers a review; one would be a read that
        // went wrong.
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerReviewFailed(DockerQueryFailure.daemonError.name),
          ),
        ];
    }
  }
}

/// Containers whose worst finding is more severe first, then by count,
/// then by name.
int _byWorst(ContainerReview a, ContainerReview b) {
  final worst = a.findings.first.risk.level.index.compareTo(
    b.findings.first.risk.level.index,
  );
  if (worst != 0) return worst;

  final count = b.findings.length.compareTo(a.findings.length);
  if (count != 0) return count;

  return a.name.compareTo(b.name);
}

/// One container's findings, each with its level, what it means and
/// what it names.
class ContainerReviewCard extends StatelessWidget {
  const ContainerReviewCard({super.key, required this.review});

  final ContainerReview review;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final project = review.project;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              project == null
                  ? review.name
                  : l10n.dockerReviewContainerInStack(review.name, project),
              style: theme.textTheme.titleSmall,
            ),
            for (final finding in review.findings)
              _FindingRow(finding: finding),
          ],
        ),
      ),
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding});

  final ContainerFinding finding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final level = finding.risk.level;
    final (icon, colour) = switch (level) {
      ContainerRiskLevel.high => (
        Icons.gpp_bad_outlined,
        theme.colorScheme.error,
      ),
      ContainerRiskLevel.medium => (
        Icons.warning_amber,
        theme.colorScheme.onSurface,
      ),
      ContainerRiskLevel.low => (
        Icons.info_outline,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final detail = finding.detail;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: colour),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  l10n.dockerReviewFinding(
                    l10n.dockerReviewLevel(level.name),
                    l10n.dockerReviewRisk(finding.risk.name),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  l10n.dockerReviewRiskWhy(finding.risk.name),
                  style: theme.textTheme.bodySmall,
                ),
                if (detail != null)
                  SelectableText(
                    detail,
                    style: klabautermannMonoStyle.copyWith(
                      fontSize: theme.textTheme.bodySmall?.fontSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

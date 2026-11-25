import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../latest_read.dart';
import 'container_badges.dart' show containerStateText;
import 'docker_notice.dart';

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

class _ReviewPanelState extends State<ReviewPanel> {
  /// The newest review's answer; null until one lands, and no read out
  /// once [LatestRead.reading] is false again.
  late final LatestRead<DockerPayload> _latest = LatestRead(
    setState: setState,
    mounted: () => mounted,
  );

  @override
  void didUpdateWidget(ReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.docker == widget.docker) {
      return;
    }

    _latest.reset();
  }

  Future<void> _review() async {
    await _latest.run(() => widget.docker.reviewContainers(widget.serverId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final run = FilledButton.tonalIcon(
      onPressed: _latest.reading ? null : () => unawaited(_review()),
      icon: const Icon(Icons.policy_outlined),
      label: Text(
        _latest.value == null ? l10n.dockerReviewRun : l10n.dockerReviewAgain,
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
    if (!_latest.reading && _latest.value == null) return const [];
    if (_latest.reading) {
      return [
        DockerNotice(
          icon: Icons.hourglass_empty,
          text: l10n.dockerReviewReading,
        ),
      ];
    }

    switch (_latest.value) {
      case DockerReviewPayload(
        :final reviews,
        :final omitted,
        :final unreadable,
        :final tools,
      ):
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
          if (unreadable > 0) ...[
            const SizedBox(height: 8),
            DockerNotice(
              icon: Icons.error_outline,
              text: l10n.dockerReviewUnreadable(unreadable),
            ),
          ],
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
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.dockerReviewToolsHeading,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final tool in tools) ...[
              const SizedBox(height: 8),
              _ToolRow(tool: tool),
            ],
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

/// DKE-17: another manager or monitor, the container it runs in and the
/// ports it publishes, each as the list labels it.
class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final HostToolContainer tool;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(Icons.extension_outlined, size: 18, color: muted),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  l10n.dockerReviewTool(tool.tool.name),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(switch (tool.state) {
                  // In the Containers sub-tab's words, not the daemon's.
                  final state? => l10n.dockerReviewToolContainer(
                    tool.name,
                    containerStateText(l10n, state),
                  ),
                  null => l10n.dockerReviewToolContainerName(tool.name),
                }, style: theme.textTheme.bodySmall),
                if (tool.ports.isEmpty)
                  Text(
                    l10n.dockerReviewToolNoPorts,
                    style: theme.textTheme.bodySmall,
                  )
                else
                  for (final port in tool.ports)
                    SelectableText(
                      port,
                      style: klabautermannMonoStyle.copyWith(
                        fontSize: theme.textTheme.bodySmall?.fontSize,
                        color: muted,
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

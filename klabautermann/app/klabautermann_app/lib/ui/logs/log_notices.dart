import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import 'log_query.dart';
import 'logs_panel_controller.dart';

/// What LOG-02's chip says, each with its own icon so the state is never
/// told by colour alone.
enum _LiveWord {
  live(Icons.fiber_manual_record),
  connecting(Icons.sync),
  disconnected(Icons.link_off),
  paused(Icons.pause_circle_outline),
  stopped(Icons.stop_circle_outlined),
  unavailable(Icons.block);

  const _LiveWord(this.icon);

  final IconData icon;
}

/// What the status line says ([AppLocalizations.logsPanelStatus]).
enum StatusWord {
  opening,
  waitingLink,
  waitingChannel,
  waitingBackground,
  gap,
  loading,
  invalid,
  missing,
  denied,
  failed,
  rejected,
  searchUnsupported,
  needsPath,
}

/// The states after which reading again may help.
const _retryable = {
  StatusWord.rejected,
  StatusWord.missing,
  StatusWord.denied,
  StatusWord.failed,
};

_LiveWord _liveWord(LogsPanelController panel) {
  // A past boot has nothing new to follow.
  if (!panel.canFollow) return _LiveWord.stopped;
  if (!panel.live) return _LiveWord.paused;
  if (panel.rejected) return _LiveWord.unavailable;
  if (!panel.ready) return _LiveWord.stopped;
  return switch (panel.status) {
    LogStreamRunning() => _LiveWord.live,
    LogStreamWaiting(reason: LogStreamWaitReason.link) =>
      _LiveWord.disconnected,
    LogStreamWaiting(reason: LogStreamWaitReason.background) =>
      _LiveWord.paused,
    LogStreamWaiting() || null => _LiveWord.connecting,
    LogStreamEnded() => _LiveWord.stopped,
  };
}

/// The word [panel]'s stream state reads as, or null while a follow runs.
StatusWord? statusWord(LogsPanelController panel) {
  if (!panel.ready) return StatusWord.needsPath;
  if (panel.rejected) return StatusWord.rejected;
  if (panel.opening) return StatusWord.opening;
  return switch (panel.status) {
    LogStreamWaiting(:final reason) => switch (reason) {
      LogStreamWaitReason.link => StatusWord.waitingLink,
      LogStreamWaitReason.channel => StatusWord.waitingChannel,
      LogStreamWaitReason.background => StatusWord.waitingBackground,
    },
    // A follow without a cursor started again after it waited (LOG-22).
    LogStreamRunning(continuity: LogContinuity.gap) when panel.live =>
      StatusWord.gap,
    LogStreamRunning() => panel.live ? null : StatusWord.loading,
    LogStreamEnded(:final reason) => switch (reason) {
      LogStreamEndReason.invalid => StatusWord.invalid,
      LogStreamEndReason.missing => StatusWord.missing,
      LogStreamEndReason.denied => StatusWord.denied,
      // Only a container's logs end for their driver, and their view
      // names it in place of this status (ContainerLogsView).
      LogStreamEndReason.failed ||
      LogStreamEndReason.logDriverUnreadable => StatusWord.failed,
      LogStreamEndReason.searchUnsupported => StatusWord.searchUnsupported,
      LogStreamEndReason.windowFilled ||
      LogStreamEndReason.oldestReached ||
      LogStreamEndReason.closed => null,
    },
    null => null,
  };
}

/// LOG-02's Live chip over [panel]'s stream: on follows, off reads a
/// window or keeps what the follow showed. It names the stream's state
/// by word and icon, never by colour alone.
class LogLiveChip extends StatelessWidget {
  const LogLiveChip({super.key, required this.panel});

  final LogsPanelController panel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final word = _liveWord(panel);
    return FilterChip(
      selected: panel.live,
      showCheckmark: false,
      avatar: Icon(word.icon, size: 18),
      label: Text(l10n.logsPanelLiveState(word.name)),
      tooltip: panel.canFollow
          ? l10n.logsPanelLiveTooltip
          : panel.containerId != null
          ? l10n.dockerLogsLiveRange
          : panel.query.source == LogSourceKind.file
          ? l10n.logsPanelLiveCompressed
          : l10n.logsPanelLivePastBoot,
      onSelected: panel.canFollow ? panel.setLive : null,
    );
  }
}

/// The status line over [panel]'s stream, a live region: what the read
/// is doing or why it stopped, with any host error output and a Retry
/// where reading again may help; nothing while a follow runs.
class LogStatusNotice extends StatelessWidget {
  const LogStatusNotice({
    super.key,
    required this.panel,
    this.container = false,
  });

  final LogsPanelController panel;

  /// Whether [panel] reads a container's log, whose missing and invalid
  /// ends name the container and its window rather than a file or filter.
  final bool container;

  @override
  Widget build(BuildContext context) {
    final word = statusWord(panel);
    if (word == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final retry = _retryable.contains(word);
    return LogNotice(
      icon: switch (word) {
        _ when retry => Icons.error_outline,
        StatusWord.gap => Icons.info_outline,
        _ => Icons.hourglass_empty,
      },
      text: switch (word) {
        StatusWord.missing ||
        StatusWord.invalid when container => l10n.dockerLogsEnded(word.name),
        _ => l10n.logsPanelStatus(word.name),
      },
      // The host's error output is server data, shown as sent.
      detail: switch (panel.status) {
        LogStreamEnded(:final detail?) => detail,
        _ => null,
      },
      action: retry
          ? TextButton(onPressed: panel.retry, child: Text(l10n.logsPanelRetry))
          : null,
      announce: true,
    );
  }
}

/// A line of state above the log: an icon, the words, and optionally the
/// host's output and an action. [announce] makes it a live region, for
/// the stream's state changes (03 §10.10).
class LogNotice extends StatelessWidget {
  const LogNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.action,
    this.announce = false,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: announce,
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: theme.textTheme.bodyMedium),
                  if (detail case final detail?)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

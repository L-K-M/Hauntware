import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import 'containers_view.dart'
    show
        ContainerFlag,
        EngineContainerState,
        containerExitCode,
        containerFlagOf;

/// A state in words; one the API does not list reads as the engine gave
/// it, and none as unknown. The Stacks sub-tab's overview shares it.
String containerStateText(AppLocalizations l10n, String? state) {
  if (state == null || state.isEmpty) return l10n.chartUnknownValue;
  return switch (EngineContainerState.of(state)) {
    final known? => l10n.dockerContainerState(known.name),
    null => state,
  };
}

/// A health status as an icon and its word, the unhealthy in the error
/// colour, so colour is never the only cue (A11Y-01); the list's rows and
/// a container's details share it.
class ContainerHealthBadge extends StatelessWidget {
  const ContainerHealthBadge({super.key, required this.health});

  final HealthStatus health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = switch (health) {
      HealthStatus.unhealthy => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Icon(
          switch (health) {
            HealthStatus.healthy => Icons.check_circle_outline,
            HealthStatus.unhealthy => Icons.error_outline,
            HealthStatus.starting => Icons.hourglass_top,
            HealthStatus.none => Icons.remove,
          },
          size: 14,
          color: color,
        ),
        Flexible(
          child: Text(
            l10n.dockerContainerHealth(health.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: health == HealthStatus.unhealthy ? color : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// A container's state in words, after an icon in the error colour when
/// CTR-09 flags it (a restart loop, a failed exit), so colour is never
/// the only cue (A11Y-01); the tooltip says why. The list's rows and a
/// stack's share it.
class ContainerStateBadge extends StatelessWidget {
  const ContainerStateBadge({
    super.key,
    required this.container,
    this.style,
    this.icon = true,
  });

  final ContainerSummary container;

  /// Whether the flag's icon leads the words; the table puts it in the
  /// row's Status cell instead.
  final bool icon;

  /// The words' style; the body text's by default.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = this.style ?? theme.textTheme.bodyMedium;
    final words = containerStateText(l10n, container.state);
    final flag = containerFlagOf(container);
    if (flag == null) {
      return Text(
        words,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      );
    }

    final error = theme.colorScheme.error;
    if (!icon) {
      return Tooltip(
        message: l10n.dockerContainerFlagTooltip(
          flag.name,
          containerExitCode(container) ?? 0,
        ),
        child: Text(
          words,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: style?.copyWith(color: error),
        ),
      );
    }
    return Tooltip(
      message: l10n.dockerContainerFlagTooltip(
        flag.name,
        containerExitCode(container) ?? 0,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Icon(
            switch (flag) {
              ContainerFlag.restartLoop => Icons.loop,
              ContainerFlag.failed => Icons.error_outline,
            },
            size: 14,
            color: error,
          ),
          Flexible(
            child: Text(
              words,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: style?.copyWith(color: error),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Status column's text, after the CTR-09 flag's icon in the error
/// colour when the row has one.
class StatusCell extends StatelessWidget {
  const StatusCell({super.key, required this.text, required this.flag});

  final String text;
  final ContainerFlag? flag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flag = this.flag;
    return Row(
      spacing: 4,
      children: [
        if (flag != null)
          Icon(
            switch (flag) {
              ContainerFlag.restartLoop => Icons.loop,
              ContainerFlag.failed => Icons.error_outline,
            },
            size: 14,
            color: theme.colorScheme.error,
          ),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// A stats figure on the end edge; a stale one grey after a history icon
/// (03 §9.5 item 4), so its age is told apart without colour.
class Figure extends StatelessWidget {
  const Figure({
    super.key,
    required this.value,
    required this.stale,
    this.risky = false,
  });

  final String value;
  final bool stale;

  /// Near a limit (CST-04): after a warning icon, in the error colour.
  final bool risky;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 2,
      children: [
        if (stale) Icon(Icons.history, size: 12, color: muted),
        if (risky && !stale)
          Icon(Icons.warning_amber, size: 12, color: theme.colorScheme.error),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            textAlign: TextAlign.end,
            // Figures line up digit under digit.
            style: theme.textTheme.bodyMedium?.copyWith(
              color: stale
                  ? muted
                  : risky
                  ? theme.colorScheme.error
                  : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

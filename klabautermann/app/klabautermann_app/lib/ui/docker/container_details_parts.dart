part of 'container_details.dart';

/// A label over its value, in the muted colour.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A line that says there is nothing to show.
class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Labelled values, each read as one node; a null value is the health
/// badge, drawn from [health].
class _Facts extends StatelessWidget {
  const _Facts({required this.facts, this.health});

  final List<(String, String?)> facts;
  final ContainerDetailsHealth? health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final health = this.health;
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Label(label),
                if (value != null)
                  Text(value, style: theme.textTheme.bodyMedium)
                else if (health != null) ...[
                  ContainerHealthBadge(health: health.status),
                  if (health.failingStreak case final streak? when streak > 0)
                    Text(
                      l10n.dockerDetailsHealthStreak(streak),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One mount: where it shows in the container, where it comes from, and
/// its type and access.
class _Mount extends StatelessWidget {
  const _Mount({required this.mount});

  final ContainerMount mount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unknown = l10n.chartUnknownValue;
    // A volume reads by its name; its source is the engine's own path.
    final source = mount.type == 'volume'
        ? mount.name ?? mount.source
        : mount.source;
    final access = switch (mount.rw) {
      true => l10n.dockerDetailsMountReadWrite,
      false => l10n.dockerDetailsMountReadOnly,
      null => unknown,
    };
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            mount.destination ?? unknown,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (source != null && source.isNotEmpty)
            Text(source, style: theme.textTheme.bodySmall),
          Text(
            l10n.dockerDetailsMountSummary(
              l10n.dockerDetailsMountKind(mount.type ?? ''),
              access,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// DKE-10's badge: the manager that owns the container, and the label
/// that says so.
class _ManagedByBadge extends StatelessWidget {
  const _ManagedByBadge({required this.marker});

  final OwnershipMarker marker;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = scheme.onSecondaryContainer;
    final manager = marker.manager.displayName;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Icon(Icons.lock_outline, size: 18, color: color),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Text(
                      l10n.dockerDetailsManagedBy(manager),
                      style: theme.textTheme.titleSmall?.copyWith(color: color),
                    ),
                    Text(
                      l10n.dockerDetailsManagedByNote(manager, marker.label),
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The inspect as raw JSON, folded until opened, from the masked model
/// ([containerDetailsJson]), and exported from there (PLT-08) through
/// LOG-10's sheet, redacted unless the user includes secrets.
class _RawJson extends StatelessWidget {
  const _RawJson({
    required this.monitoring,
    required this.container,
    required this.name,
  });

  final MonitoringController monitoring;
  final ContainerDetails container;

  /// The container's name, for the file's.
  final String name;

  void _export(BuildContext context, String json) {
    final l10n = AppLocalizations.of(context);
    unawaited(
      showExportSheet(
        context,
        monitoring: monitoring,
        lines: const LineSplitter().convert(json),
        fileName: l10n.dockerDetailsRawFileName(name),
        title: l10n.dockerDetailsRawExportTitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        l10n.dockerDetailsRawTitle,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        l10n.dockerDetailsRawNote,
        style: theme.textTheme.bodySmall,
      ),
      children: [
        // Built only once opened.
        Builder(
          builder: (context) {
            final json = containerDetailsJson(container);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      json,
                      style: theme.textTheme.bodySmall?.merge(_monoStyle),
                    ),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _export(context, json),
                    icon: const Icon(Icons.ios_share),
                    label: Text(l10n.logsExport),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

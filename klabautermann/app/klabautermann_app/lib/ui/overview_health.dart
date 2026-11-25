part of 'overview_panel.dart';

/// How many unhealthy containers the health card names before "and N
/// more", as the failed units summary does.
const int _maxUnhealthyShown = 5;

/// What a [DiskAlarm] measures of its mount.
enum DiskMeasure { space, inodes }

/// A listed mount whose space or inode use is at or past a level (OV-02).
typedef DiskAlarm = ({
  String mountPoint,
  DiskMeasure measure,
  int percent,
  ChartSeverity severity,
});

/// [fs]'s mounts whose space or inode use reaches [levels]' warning level
/// (OV-02, OV-11), the most severe and fullest first; the careful band
/// raises none. Pseudo filesystems stay out, as in the Disks card: a
/// squashfs image is always full.
List<DiskAlarm> diskAlarms(
  FsSnapshot fs, {
  ChartThresholds levels = kDefaultThresholds,
}) {
  final alarms = <DiskAlarm>[];
  for (final mount in shownMounts(fs, showPseudo: false)) {
    for (final (measure, percent) in [
      (DiskMeasure.space, mount.capacityPercent),
      (DiskMeasure.inodes, mount.inodeUsePercent),
    ]) {
      if (percent == null) continue;
      final severity = levels.severityOf(percent.toDouble());
      if (!severity.alarms) continue;
      alarms.add((
        mountPoint: mount.mountPoint,
        measure: measure,
        percent: percent,
        severity: severity,
      ));
    }
  }
  return alarms..sort((a, b) {
    final bySeverity = b.severity.index.compareTo(a.severity.index);
    return bySeverity != 0 ? bySeverity : b.percent.compareTo(a.percent);
  });
}

/// OV-02's unhealthy containers beside the failed units: how many, then
/// each one's name with the engine's status text, in the failed units
/// summary's shape. The Docker tab has no route to one container yet,
/// so the names are plain text.
class _UnhealthyContainers extends StatelessWidget {
  const _UnhealthyContainers({required this.unhealthy, required this.stale});

  final List<ContainerSummary> unhealthy;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final none = unhealthy.isEmpty;
    final color = none || stale
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    final hidden = unhealthy.length - _maxUnhealthyShown;
    final line = stale
        ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Semantics(
          header: true,
          child: Row(
            spacing: 8,
            children: [
              Icon(
                none ? Icons.check_circle_outline : Icons.error_outline,
                color: color,
                size: 20,
              ),
              Flexible(
                child: Text(
                  l10n.overviewHealthContainersUnhealthy(unhealthy.length),
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
        for (final container in unhealthy.take(_maxUnhealthyShown))
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text(
              l10n.overviewHealthContainer(
                containerNameOf(container),
                container.status ?? l10n.chartUnknownValue,
              ),
              style: line,
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28),
            child: Text(
              l10n.servicesFailedMore(hidden),
              style: theme.textTheme.bodySmall?.copyWith(
                color: stale ? theme.colorScheme.onSurfaceVariant : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// How the health card's link words the A11Y-15 switch.
enum _SwitchState { on, off }

/// The health, Disks and Host cards over [slow]'s readings and the `core`
/// reading's uptime and boot time.
final class _PartTwo {
  const _PartTwo({
    required this.serverId,
    required this.slow,
    required this.docker,
    required this.core,
    required this.coreStale,
    required this.diskFreshness,
    required this.healthFreshness,
  });

  final String serverId;
  final _Slow slow;
  final _Docker docker;
  final CoreResult? core;
  final bool coreStale;
  final Freshness diskFreshness, healthFreshness;

  /// A slow card's age, or null: a pause or a lost link is said once, by
  /// the panel's first line, though it greys these values too.
  static Widget? _ageLine(AppLocalizations l10n, Freshness freshness) =>
      freshness is FreshnessUpdated
      ? PanelNotice(
          icon: freshness.stale ? Icons.history : Icons.schedule,
          text: freshnessText(l10n, freshness),
        )
      : null;

  static IconData _reasonIcon(CollectorUnavailable unavailable) =>
      unavailable.reason == CollectorUnavailableReason.timeout
      ? Icons.timer_off_outlined
      : Icons.error_outline;

  /// OV-02: failed units through K34's summary and, with a Docker
  /// endpoint, the unhealthy containers, then the mounts past a level, and
  /// the doctor (TRI-01) and the link to A11Y-15's switch in Settings
  /// (D60).
  Widget health(
    BuildContext context,
    AnnouncementScope? scope, {
    required VoidCallback onDoctor,
  }) {
    final l10n = AppLocalizations.of(context);
    final stale = healthFreshness.stale;
    final unitsFailed = switch (slow.failed.value?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final announce = scope?.notifier?.value ?? false;
    return PanelSection(
      title: l10n.overviewHealthTitle,
      children: [
        ?_ageLine(l10n, healthFreshness),
        if (unitsFailed != null)
          PanelNotice(
            icon: _reasonIcon(unitsFailed),
            text: l10n.overviewHealthUnitsCheckFailed(unitsFailed.reason.name),
            detail: unitsFailed.detail,
          ),
        if (slow.failedReading.value?.result case FailedUnitsResult(
          :final failed,
        ))
          FailedUnitsSummary(failed: failed, stale: stale)
        else if (unitsFailed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewHealthUnitsWaiting,
          ),
        if (docker.shown)
          if (docker.containers.value.containers case final containers?)
            _UnhealthyContainers(
              unhealthy: [
                for (final container in containers)
                  if (container.health == HealthStatus.unhealthy) container,
              ],
              stale: docker.stale,
            ),
        ..._diskHealth(context, l10n, stale),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: onDoctor,
            icon: const Icon(Icons.medical_services_outlined),
            label: Text(l10n.doctorOpen),
          ),
        ),
        if (scope != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            // The label states the switch, so the hint says that the
            // button opens Settings rather than flipping it here.
            child: MergeSemantics(
              child: Semantics(
                hint: l10n.overviewHealthAnnouncementsHint,
                child: TextButton.icon(
                  onPressed: () => scope.openSettings(context),
                  icon: Icon(
                    announce
                        ? Icons.record_voice_over_outlined
                        : Icons.voice_over_off_outlined,
                  ),
                  label: Text(
                    l10n.overviewHealthAnnouncements(
                      (announce ? _SwitchState.on : _SwitchState.off).name,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A failed `df` makes every mount's use unknown, so it names no mount
  /// from an older reading.
  List<Widget> _diskHealth(
    BuildContext context,
    AppLocalizations l10n,
    bool stale,
  ) {
    if (slow.fsFailure case final unavailable?) {
      return [
        PanelNotice(
          icon: _reasonIcon(unavailable),
          text: l10n.overviewHealthDisksUnknown(unavailable.reason.name),
        ),
      ];
    }
    final listed = slow.listed.value?.result;
    if (listed is! FsResult) {
      return [
        PanelNotice(
          icon: Icons.hourglass_empty,
          text: l10n.overviewDisksWaiting,
        ),
      ];
    }

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final levels = ThresholdScope.of(context, ThresholdMetric.disk);
    final alarms = diskAlarms(listed.fs, levels: levels);
    if (alarms.isEmpty) {
      return [
        _IconLine(
          icon: Icons.check_circle_outline,
          color: muted,
          text: l10n.overviewHealthDisksOk(
            l10n.chartPercent(levels.warning / 100),
          ),
          stale: stale,
        ),
      ];
    }
    final palette = ChartPalette.of(context);
    return [
      for (final alarm in alarms)
        _IconLine(
          icon: alarm.severity == ChartSeverity.critical
              ? Icons.error_outline
              : Icons.warning_amber_outlined,
          color: stale ? muted : palette.severityColor(alarm.severity) ?? muted,
          text: switch (alarm.measure) {
            DiskMeasure.inodes => l10n.overviewHealthDiskInodes(
              alarm.mountPoint,
              l10n.chartPercent(alarm.percent / 100),
              alarm.severity.name,
            ),
            DiskMeasure.space => l10n.overviewHealthDiskSpace(
              alarm.mountPoint,
              l10n.chartPercent(alarm.percent / 100),
              alarm.severity.name,
            ),
          },
          stale: stale,
        ),
    ];
  }
}

/// A state in words beside an icon of its own shape, read as one node;
/// the colour adds emphasis only (A11Y-01).
class _IconLine extends StatelessWidget {
  const _IconLine({
    required this.icon,
    required this.color,
    required this.text,
    required this.stale,
  });

  final IconData icon;
  final Color color;
  final String text;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 20, color: color),
          Expanded(child: Text(text, style: _valueStyle(context, stale))),
        ],
      ),
    );
  }
}

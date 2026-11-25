part of 'overview_panel.dart';

/// How many mounts the Disks card lists before pointing to the System tab,
/// which lists them all; the health card names every full one.
const int _maxMountsShown = 8;

/// The Disks and Host cards' portions of [_PartTwo].
extension _PartTwoHostDisks on _PartTwo {
  /// DSK-01 and DSK-02 as K37's System tab reads them: the listed mounts,
  /// after a `df` timeout the last reading's mounts with their use
  /// unknown, since which mount hung is not known, and after another
  /// failure only why.
  Widget disks(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final listed = switch (slow.listed.value) {
      Sample(:final at, result: FsResult(:final fs)) => (at: at, fs: fs),
      _ => null,
    };
    final unavailable = slow.fsFailure;
    final timedOut = unavailable?.reason == CollectorUnavailableReason.timeout;
    final shown = unavailable == null || timedOut ? listed : null;
    return PanelSection(
      title: l10n.systemDisksTitle,
      children: [
        if (shown != null) ?_PartTwo._ageLine(clock, ticking, diskFreshness),
        if (timedOut) ...[
          PanelNotice(
            icon: Icons.timer_off_outlined,
            text: l10n.systemDisksTimedOut,
          ),
          if (listed != null)
            Text(
              l10n.systemDisksLastListed(
                displayTime(context, serverId, listed.at),
              ),
            ),
        ] else if (unavailable != null)
          PanelNotice(
            icon: _PartTwo._reasonIcon(unavailable),
            text: l10n.overviewUnavailable(unavailable.reason.name),
            detail: unavailable.detail,
          )
        else if (listed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewDisksWaiting,
          )
        else if (listed.fs.timeoutAbsent)
          PanelNotice(
            icon: Icons.info_outline,
            text: l10n.systemDisksNoTimeout,
          ),
        if (shown != null)
          ..._mounts(context, l10n, shown.fs, timedOut: timedOut),
      ],
    );
  }

  List<Widget> _mounts(
    BuildContext context,
    AppLocalizations l10n,
    FsSnapshot fs, {
    required bool timedOut,
  }) {
    final mounts = shownMounts(fs, showPseudo: false);
    if (mounts.isEmpty) return [Text(l10n.systemDisksEmpty)];

    final stale = diskFreshness(clock.value).stale;
    String? percent(int? value) =>
        value == null || timedOut ? null : l10n.chartPercent(value / 100);
    return [
      for (final mount in mounts.take(_maxMountsShown))
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Text(
              mount.mountPoint,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (!timedOut)
              StackedBar(
                label: mount.mountPoint,
                segments: [
                  BarSegment(
                    label: l10n.systemColumnUsed,
                    value: mount.usedBytes?.toDouble(),
                  ),
                ],
                total: _diskBase(mount)?.toDouble(),
                unit: ChartUnit.bytes,
                strings: klabautermannChartStrings(l10n),
                thresholds: ThresholdScope.of(context, ThresholdMetric.disk),
                stale: stale,
              ),
            _Facts(
              stale: stale,
              facts: [
                (l10n.systemColumnUse, percent(mount.capacityPercent)),
                (
                  l10n.overviewDiskSize,
                  timedOut ? null : _Cards._bytes(l10n, mount.sizeBytes),
                ),
                (l10n.systemColumnInodes, percent(mount.inodeUsePercent)),
              ],
            ),
          ],
        ),
      if (mounts.length > _maxMountsShown)
        Text(l10n.overviewDisksMore(mounts.length - _maxMountsShown)),
    ];
  }

  /// What `df` computes a mount's share on: the used plus the available
  /// space (reserved blocks count in neither), else the size, so bar and
  /// figure agree as in the System tab.
  static int? _diskBase(FsMount mount) {
    final used = mount.usedBytes;
    final avail = mount.availBytes;
    return used != null && avail != null ? used + avail : mount.sizeBytes;
  }

  /// SYS-01's OS and kernel from `identity`, and BOOT-01's uptime and boot
  /// time from `core`, unknown with D50's reason where the container's
  /// `/proc` file would give the host's. Before a reading the card waits,
  /// and a failed one says why above the last values, as the System tab
  /// and part one's cards do; the panel's first notices speak for `core`.
  Widget host(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identityFailed = switch (slow.identityLatest.value?.result) {
      final CollectorUnavailable unavailable => unavailable,
      _ => null,
    };
    final identity = switch (slow.identity.value?.result) {
      final IdentityResult identity => identity,
      _ => null,
    };
    final profile = slow.profile.value;
    final uptimeWithheld = withholdsHostFigure(
      profile,
      SystemWideProcFile.uptime,
    );
    final bootWithheld = withholdsHostFigure(profile, SystemWideProcFile.stat);
    final core = this.core;
    final uptime = uptimeWithheld ? null : core?.uptime;
    final booted = bootWithheld ? null : core?.bootedAt;
    return PanelSection(
      title: l10n.overviewHostTitle,
      children: [
        if (identityFailed != null)
          PanelNotice(
            icon: _PartTwo._reasonIcon(identityFailed),
            text: l10n.overviewUnavailable(identityFailed.reason.name),
            detail: identityFailed.detail,
          ),
        if (identity != null)
          // Read once per session (03 §6.4), so with no age of its own:
          // it greys with the `core` cards once the panel's line says
          // stale.
          _Facts(
            stale: core != null && coreStale,
            facts: [
              (l10n.systemOperatingSystem, identity.osPrettyName),
              (l10n.systemKernel, kernelText(l10n, identity)),
            ],
          )
        else if (identityFailed == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewHostWaiting,
          ),
        if (core != null) ...[
          _Facts(
            stale: coreStale,
            facts: [
              (
                l10n.systemUptime,
                uptime == null ? null : uptimeText(l10n, uptime),
              ),
              (
                l10n.systemBooted,
                booted == null
                    ? null
                    : l10n.systemBootedValue(
                        displayTime(context, serverId, booted),
                      ),
              ),
            ],
          ),
          if (uptimeWithheld || bootWithheld)
            PanelNotice(
              icon: Icons.info_outline,
              text: uptimeWithheld && bootWithheld
                  ? l10n.overviewUnknownContainer
                  : l10n.systemUnknownContainer,
            ),
        ],
      ],
    );
  }
}

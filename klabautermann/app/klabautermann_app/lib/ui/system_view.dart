import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';

/// Whether the System tab withholds a figure read from [file] on the
/// system [profile] describes: shown as unknown with D50's reason,
/// whatever the reading holds, so a container host's number never passes
/// for the container's own (SYS-04). While the profile cannot tell
/// (`showsHostFigures` is null, as on a host with neither
/// `systemd-detect-virt` nor lxcfs mounts) or has not arrived, the figure
/// stays as measured: counting such hosts as containers would blank it on
/// all of them.
bool withholdsHostFigure(HostProfile? profile, SystemWideProcFile file) =>
    profile?.showsHostFigures(file) ?? false;

/// What `systemd-detect-virt` prints for no virtualization.
const _detectVirtNone = 'none';

/// Whether [profile] puts the system in a container: `systemd-detect-virt
/// -c` named one, or an lxcfs mount over `/proc` shows that it is one
/// even where that tool answered `none` (D50).
bool inContainer(HostProfile? profile) {
  if (profile == null) return false;
  if (profile.lxcfsMounts?.isNotEmpty ?? false) return true;

  final container = profile.container;
  return container != null && container != _detectVirtNone;
}

/// SYS-01's virtualization in words, or null while unknown: no probe
/// answer yet, or a host with neither `systemd-detect-virt` nor lxcfs
/// mounts. That tool reports a container ahead of the machine it runs in,
/// so a container counts as one whatever its plain answer. A technology's
/// name (`kvm`, `lxc`) is server data and never translated.
String? virtualizationText(AppLocalizations l10n, HostProfile? profile) {
  if (profile == null) return null;

  final container = profile.container;
  if (container != null && container != _detectVirtNone) {
    return l10n.systemVirtualizationContainer(container);
  }
  if (inContainer(profile)) return l10n.systemVirtualizationContainerUnnamed;

  return switch (profile.virtualization) {
    null => null,
    _detectVirtNone => l10n.systemVirtualizationNone,
    final machine => l10n.systemVirtualizationMachine(machine),
  };
}

/// NET-01's total receive and transmit rates over every interface the host
/// reported, in bytes per second; null while [network] is (the first
/// reading, after a counter reset), so unknown never sums to zero (03
/// §1.2 principle 6). An empty map, a host that reported no interface,
/// totals zero.
({double rx, double tx})? networkTotals(Map<String, NetRate>? network) {
  if (network == null) return null;

  var rx = 0.0;
  var tx = 0.0;
  for (final rate in network.values) {
    rx += rate.rxBytesPerSecond;
    tx += rate.txBytesPerSecond;
  }
  return (rx: rx, tx: tx);
}

/// SYS-01's kernel as `uname` names it, name and release, or whichever
/// the host reported; null when neither.
String? kernelText(AppLocalizations l10n, IdentityResult identity) =>
    switch ((identity.kernelName, identity.kernelRelease)) {
      (final name?, final release?) => l10n.systemKernelValue(name, release),
      (final name?, null) => name,
      (null, final release?) => release,
      (null, null) => null,
    };

/// BOOT-01's uptime in words: whole days and hours from a day on, hours
/// and minutes from an hour on, else minutes. Each part rounds down, so a
/// host never reads as up longer than it has been.
String uptimeText(AppLocalizations l10n, Duration uptime) {
  final days = uptime.inDays;
  final hours = uptime.inHours.remainder(Duration.hoursPerDay);
  final minutes = uptime.inMinutes.remainder(Duration.minutesPerHour);
  if (days > 0) return l10n.systemUptimeDays(days, hours);
  if (hours > 0) return l10n.systemUptimeHours(hours, minutes);
  return l10n.systemUptimeMinutes(minutes);
}

/// The skew below which a server's clock reads as in step: the probe
/// reads whole seconds, and its answer's transit adds a little more.
const kClockInStep = Duration(seconds: 2);

/// CN-17's words for [skew], the server's time less this device's; null
/// before a probe measured it.
String? clockSkewText(AppLocalizations l10n, Duration? skew) {
  if (skew == null) return null;
  final size = skew.abs();
  if (size < kClockInStep) return l10n.systemClockInStep;
  final amount = size < const Duration(minutes: 2)
      ? l10n.systemClockSeconds(size.inSeconds)
      : size < const Duration(hours: 2)
      ? l10n.systemClockMinutes(size.inMinutes)
      : l10n.systemClockHours(size.inHours);
  return skew.isNegative
      ? l10n.systemClockBehind(amount)
      : l10n.systemClockAhead(amount);
}

/// SYS-02's words for [profile]'s time sync; null where timedatectl did
/// not say.
String? timeSyncText(AppLocalizations l10n, HostProfile? profile) =>
    switch ((profile?.ntpEnabled, profile?.ntpSynchronized)) {
      (_, true) => l10n.systemTimeSynced,
      (false, _) => l10n.systemTimeSyncOff,
      (_, false) => l10n.systemTimeNotSynced,
      _ => null,
    };

/// DSK-01's mounts in `df` order: without the pseudo filesystems the host
/// marks by type (tmpfs, devtmpfs, overlay, squashfs, erofs; 03 §7.3)
/// unless [showPseudo].
List<FsMount> shownMounts(FsSnapshot fs, {required bool showPseudo}) => [
  for (final mount in fs.mounts)
    if (showPseudo || !mount.isPseudo) mount,
];

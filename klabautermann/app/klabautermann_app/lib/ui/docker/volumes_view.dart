import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary, VolumeSummary;

/// The Volumes sub-tab's columns, whose names key them in the table and
/// its sort (03 §7.15 VOL-01).
enum VolumeColumn { name, driver, created, use }

/// Which volumes the Volumes sub-tab lists (VOL-01): every one, or those
/// no container mounts.
enum VolumeFilter { all, unused }

/// The mount type of a named volume in a container's `Mounts`.
const _volumeMount = 'volume';

/// How many containers, running or not, mount each volume, by name, as
/// [containers] (the full list) name them.
Map<String, int> containersByVolume(List<ContainerSummary> containers) {
  final counts = <String, int>{};
  for (final container in containers) {
    // A container that mounts one volume twice still uses it once.
    final names = {
      for (final mount in container.mounts)
        if (mount.type == _volumeMount) ?mount.name,
    };
    for (final name in names) {
      counts.update(name, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return counts;
}

/// The names Docker accepts for a volume or a driver, as the engine's
/// planner checks them (VOL-02).
final _volumeName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]+$');

/// Whether [name] is one Docker accepts for a volume or a driver: a
/// letter or digit, then at least one more letter, digit, `_`, `.` or
/// `-`.
bool validVolumeName(String name) => _volumeName.hasMatch(name);

/// One volume the tab lists, with how many containers mount it.
final class VolumeEntry {
  const VolumeEntry(this.volume, this.containers);

  final VolumeSummary volume;

  /// How many containers mount [volume], or null while no container list
  /// was read: the volume list itself carries no count.
  final int? containers;

  /// Whether no container mounts [volume]; false while unknown.
  bool get unused => containers == 0;
}

/// [volumes] as the tab lists them: those [filter] and [terms] keep, in
/// the engine's order, each with its use counted from [containers] when
/// one was read.
List<VolumeEntry> volumeEntries(
  List<VolumeSummary> volumes, {
  required List<ContainerSummary>? containers,
  required VolumeFilter filter,
  required List<String> terms,
}) {
  final byVolume = containers == null ? null : containersByVolume(containers);
  return [
    for (final volume in volumes)
      if (VolumeEntry(
            volume,
            byVolume == null ? null : byVolume[volume.name] ?? 0,
          )
          case final entry
          when (filter == VolumeFilter.all || entry.unused) &&
              volumeMatches(volume, terms))
        entry,
  ];
}

/// Whether every term of [terms] is in [volume]'s name or driver.
bool volumeMatches(VolumeSummary volume, List<String> terms) {
  if (terms.isEmpty) return true;

  final haystack = [volume.name, ?volume.driver].join('\n').toLowerCase();
  return terms.every(haystack.contains);
}

import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary, VolumeSummary;

import 'docker_resource_view.dart';

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
Map<String, int> containersByVolume(List<ContainerSummary> containers) =>
    countContainerUse(containers, (container) {
      // A container that mounts one volume twice still uses it once.
      return {
        for (final mount in container.mounts)
          if (mount.type == _volumeMount) ?mount.name,
      };
    });

/// The names Docker accepts for a volume, as the engine's planner checks
/// them (VOL-02).
final _volumeName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]+$');

/// Whether [name] is one Docker accepts for a volume: a letter or digit,
/// then at least one more letter, digit, `_`, `.` or `-`.
bool validVolumeName(String name) => _volumeName.hasMatch(name);

/// One volume the tab lists, with how many containers mount it.
final class VolumeEntry extends DockerResourceEntry<VolumeSummary> {
  const VolumeEntry(super.summary, super.containers);

  VolumeSummary get volume => summary;
}

/// [volumes] as the tab lists them: those [filter] and [terms] keep, in
/// the engine's order, each with its use counted from [containers] when
/// one was read.
List<VolumeEntry> volumeEntries(
  List<VolumeSummary> volumes, {
  required List<ContainerSummary>? containers,
  required VolumeFilter filter,
  required List<String> terms,
}) => dockerResourceEntries(
  volumes,
  countUse: containersByVolume,
  create: VolumeEntry.new,
  keeps: (entry, filter) => filter == VolumeFilter.all || entry.unused,
  matches: volumeMatches,
  nameOf: (volume) => volume.name,
  containers: containers,
  filter: filter,
  terms: terms,
);

/// Whether every term of [terms] is in [volume]'s name or driver.
bool volumeMatches(VolumeSummary volume, List<String> terms) =>
    matchesTerms(terms, [volume.name, ?volume.driver]);

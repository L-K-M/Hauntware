import 'package:meta/meta.dart';

import 'models/events.dart';

/// The lists the Docker views refresh from engine events (03 §7.12
/// DKE-02).
enum DockerList {
  containers,
  images,
  volumes,
  networks,
  engineInfo,
  stacks;

  /// Every list, for a full re-list.
  static Set<DockerList> get all => DockerList.values.toSet();
}

/// 03 §7.12 DKE-02: a reconnect gap over this forces a full re-list
/// instead of a targeted one.
const Duration eventGapThreshold = Duration(seconds: 60);

/// What to refresh after one event (03 §7.12 DKE-02).
@immutable
final class EventRefreshPlan {
  const EventRefreshPlan({required this.lists});

  final Set<DockerList> lists;

  bool get isEmpty => lists.isEmpty;
}

/// Maps one event to the lists it invalidates (03 §7.12 DKE-02).
Set<DockerList> listsForEvent(DockerEvent event) => switch (event.type) {
  'container' => {DockerList.containers, DockerList.stacks},
  'image' => {DockerList.images},
  'volume' => {DockerList.volumes},
  'network' => {DockerList.networks},
  'daemon' => {DockerList.engineInfo},
  _ => const <DockerList>{},
};

/// The event-refresh decision (03 §7.12 DKE-02): the targeted lists one
/// event invalidates. A reconnect gap is not decided here; the watcher
/// owns that (`_lostAt`) and re-lists past its threshold itself.
EventRefreshPlan planEventRefresh({required DockerEvent event}) =>
    EventRefreshPlan(lists: listsForEvent(event));

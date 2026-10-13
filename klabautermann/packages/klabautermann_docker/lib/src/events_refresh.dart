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
  const EventRefreshPlan({
    required this.lists,
    this.fullRelist = false,
    this.reason,
  });

  final Set<DockerList> lists;
  final bool fullRelist;
  final String? reason;

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

/// Pure event-refresh decision (03 §7.12 DKE-02): a targeted list for a
/// normal event, or every list after a gap over [gap]. [previousEventAt]
/// is the timestamp of the last event seen before this one; null means no
/// gap is known, so the targeted path is used.
EventRefreshPlan planEventRefresh({
  required DockerEvent event,
  required DateTime now,
  DateTime? previousEventAt,
  Duration gap = eventGapThreshold,
}) {
  if (previousEventAt != null && now.difference(previousEventAt) > gap) {
    return EventRefreshPlan(
      lists: DockerList.all,
      fullRelist: true,
      reason:
          'event gap of ${now.difference(previousEventAt).inSeconds}s '
          'exceeds ${gap.inSeconds}s',
    );
  }
  return EventRefreshPlan(lists: listsForEvent(event));
}

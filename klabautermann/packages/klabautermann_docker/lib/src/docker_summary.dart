import 'package:meta/meta.dart';

import 'models/container.dart';
import 'models/image.dart';
import 'models/system_df.dart';

/// The Docker summary card's figures (02 OV-05, 03 §7.1): container
/// counts from the event-driven container cache, image counts from the
/// image list, and reclaimable space from `/system/df`, which is fetched
/// on demand because it is slow on large hosts.
@immutable
final class DockerSummary {
  const DockerSummary({
    required this.running,
    required this.paused,
    required this.stopped,
    required this.unhealthy,
    required this.images,
    required this.imagesInUse,
    required this.danglingImages,
    this.reclaimableBytes,
  });

  /// Containers in the `running` state.
  final int running;

  /// Containers in the `paused` state.
  final int paused;

  /// Every other container: created, restarting, exited, dead, removing,
  /// or a state the daemon did not name. This is `docker info`'s split.
  final int stopped;

  /// Containers whose health check reports unhealthy (02 OV-02).
  final int unhealthy;
  final int images;

  /// Images at least one container (running or not) was created from.
  final int imagesInUse;
  final int danglingImages;

  /// Reclaimable bytes from `/system/df`; null until it was fetched or
  /// when it reported no reclaimable figure.
  final int? reclaimableBytes;
}

/// Computes the OV-05 summary (03 §7.1). [containers] is the full list
/// (`all=1`); [images] is `/images/json` parsed through the 1.51 gate;
/// [df] is the last `/system/df` result, if any.
///
/// An image is in use when a container in [containers] was created from
/// it ([imageContainerCount]): the engine re-lists the containers on a
/// container event but not the images, so the count the image list
/// carries from API 1.51 lags, and the Images tab counts the same way
/// (03 §7.14).
DockerSummary dockerSummary(
  List<ContainerSummary> containers,
  List<ImageSummary> images, [
  SystemDf? df,
]) {
  var running = 0;
  var paused = 0;
  var stopped = 0;
  var unhealthy = 0;
  for (final c in containers) {
    switch (c.state) {
      case 'running':
        running++;
      case 'paused':
        paused++;
      default:
        stopped++;
    }
    if (c.health == HealthStatus.unhealthy) unhealthy++;
  }

  final byImage = containersByImage(containers);
  var inUse = 0;
  var dangling = 0;
  for (final i in images) {
    if ((imageContainerCount(i, byImage) ?? 0) > 0) inUse++;
    if (i.isDangling) dangling++;
  }

  return DockerSummary(
    running: running,
    paused: paused,
    stopped: stopped,
    unhealthy: unhealthy,
    images: images.length,
    imagesInUse: inUse,
    danglingImages: dangling,
    reclaimableBytes: df?.reclaimable,
  );
}

/// The digest algorithm Docker prefixes image ids with.
const _sha256Prefix = 'sha256:';

/// [id] without its `sha256:` prefix, so an image's id and a container's
/// `ImageID` match whichever of them carries it.
String bareImageId(String id) =>
    id.startsWith(_sha256Prefix) ? id.substring(_sha256Prefix.length) : id;

/// How many containers, running or not, were created from each image,
/// by [bareImageId], as [containers] (the full list) name them.
Map<String, int> containersByImage(List<ContainerSummary> containers) {
  final counts = <String, int>{};
  for (final container in containers) {
    final imageId = container.imageId;
    if (imageId == null || imageId.isEmpty) continue;
    counts.update(bareImageId(imageId), (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

/// How many containers use [image], or null when nothing tells.
///
/// The container list counts, whenever one was read ([byImage], from
/// [containersByImage]): the engine re-lists the containers on a
/// container event but not the images, so an image's own count lags a
/// container created or removed. Without a container list, the count the
/// image list carries from API 1.51 stands in; below 1.51 it has none,
/// and a negative count is one the daemon did not compute.
int? imageContainerCount(ImageSummary image, Map<String, int>? byImage) {
  if (byImage != null) return byImage[bareImageId(image.id)] ?? 0;

  final count = image.containers;
  if (count == null || count < 0) return null;
  return count;
}

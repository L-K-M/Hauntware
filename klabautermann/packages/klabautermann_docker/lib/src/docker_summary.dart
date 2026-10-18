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
/// An image's `Containers` count is used when the daemon reported one
/// (API 1.51 and later). Below that it is null, and an image is in use
/// when a container's `ImageID` names it (03 §7.14).
DockerSummary dockerSummary(
  List<ContainerSummary> containers,
  List<ImageSummary> images, [
  SystemDf? df,
]) {
  var running = 0;
  var paused = 0;
  var stopped = 0;
  var unhealthy = 0;
  final containerImageIds = <String>{};
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
    final imageId = c.imageId;
    if (imageId != null) containerImageIds.add(_bareImageId(imageId));
  }

  var inUse = 0;
  var dangling = 0;
  for (final i in images) {
    final count = i.containers;
    // -1 means the daemon did not compute the count.
    final used = count != null && count >= 0
        ? count > 0
        : containerImageIds.contains(_bareImageId(i.id));
    if (used) inUse++;
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

/// Image ids compare without the `sha256:` prefix, so a bare id on
/// either side still matches.
String _bareImageId(String id) =>
    id.startsWith('sha256:') ? id.substring('sha256:'.length) : id;

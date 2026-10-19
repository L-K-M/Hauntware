import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary, ImageSummary;

import 'containers_view.dart' show shortContainerId;

/// The Images sub-tab's columns, whose names key them in the table and
/// its sort (03 §7.14 IMG-01).
enum ImageColumn { tags, id, size, created, use }

/// Which images the Images sub-tab lists (IMG-01): every one, those no
/// container uses, or the dangling ones, which have no tag.
enum ImageFilter { all, unused, dangling }

/// The tag `docker images` prints as `<none>:<none>`, which names no tag.
const _untagged = '<none>:<none>';

/// The digest algorithm Docker prefixes image ids with.
const _sha256Prefix = 'sha256:';

/// [id] without its `sha256:` prefix, so an image's id and a container's
/// `ImageID` match whichever of them carries it.
String bareImageId(String id) =>
    id.startsWith(_sha256Prefix) ? id.substring(_sha256Prefix.length) : id;

/// [id] as `docker images` shortens it: the digest without its algorithm,
/// cut to 12 characters.
String shortImageId(String id) {
  final colon = id.indexOf(':');
  return shortContainerId(colon < 0 ? id : id.substring(colon + 1));
}

/// [image]'s tags, `repository:tag`, without the untagged placeholder.
List<String> imageTagsOf(ImageSummary image) => [
  for (final tag in image.repoTags)
    if (tag != _untagged && tag.isNotEmpty) tag,
];

/// [tags] on one line, the engine's names comma-separated, as the
/// Containers sub-tab lists a container's ports.
String imageTagsText(List<String> tags) => tags.join(', ');

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

/// One image the tab lists, with how many containers use it.
final class ImageEntry {
  const ImageEntry(this.image, this.containers);

  final ImageSummary image;

  /// How many containers use [image], or null when unknown
  /// ([imageContainerCount]).
  final int? containers;

  List<String> get tags => imageTagsOf(image);

  bool get dangling => image.isDangling;

  /// Whether no container uses [image]; false while unknown.
  bool get unused => containers == 0;
}

/// [images] as the tab lists them: those [filter] and [terms] keep, in
/// the engine's order, each with its use counted from [containers] when
/// one was read.
List<ImageEntry> imageEntries(
  List<ImageSummary> images, {
  required List<ContainerSummary>? containers,
  required ImageFilter filter,
  required List<String> terms,
}) {
  final byImage = containers == null ? null : containersByImage(containers);
  return [
    for (final image in images)
      if (ImageEntry(image, imageContainerCount(image, byImage))
          case final entry
          when _kept(entry, filter) && imageMatches(image, terms))
        entry,
  ];
}

bool _kept(ImageEntry entry, ImageFilter filter) => switch (filter) {
  ImageFilter.all => true,
  ImageFilter.unused => entry.unused,
  ImageFilter.dangling => entry.dangling,
};

/// Whether every term of [terms] is in [image]'s tags or id.
bool imageMatches(ImageSummary image, List<String> terms) {
  if (terms.isEmpty) return true;

  final haystack = [...imageTagsOf(image), image.id].join('\n').toLowerCase();
  return terms.every(haystack.contains);
}

/// The steps an image's age is told in, as Docker's `HumanDuration`
/// grades them, so the tab reads like `docker images`: minutes under an
/// hour, hours under two days, days under two weeks, weeks under two
/// months, months (of 30 days) under two years, then years (of 365).
enum ImageAgeUnit { lessThanMinute, minutes, hours, days, weeks, months, years }

/// [age] as a count of its [ImageAgeUnit]; a negative age (a clock set
/// back) reads as none. As in `HumanDuration`, minutes round down, hours
/// round to the nearest and grade every unit up to months, and years
/// round down from the age itself.
(ImageAgeUnit, int) imageAge(Duration age) {
  if (age < const Duration(minutes: 1)) return (ImageAgeUnit.lessThanMinute, 0);
  if (age < const Duration(hours: 1)) {
    return (ImageAgeUnit.minutes, age.inMinutes);
  }
  final hours = (age.inMinutes + 30) ~/ 60;
  if (hours < 48) return (ImageAgeUnit.hours, hours);
  if (hours < 24 * 14) return (ImageAgeUnit.days, hours ~/ 24);
  if (hours < 24 * 60) return (ImageAgeUnit.weeks, hours ~/ 24 ~/ 7);
  if (hours < 24 * 730) return (ImageAgeUnit.months, hours ~/ 24 ~/ 30);
  return (ImageAgeUnit.years, age.inDays ~/ 365);
}

import 'package:klabautermann_core/klabautermann_core.dart'
    show
        ContainerSummary,
        ImageSummary,
        ImageUpdateRow,
        ImageUpdateStatus,
        containersByImage,
        imageContainerCount;

import 'containers_view.dart' show shortContainerId;

/// The Images sub-tab's columns, whose names key them in the table and
/// its sort (03 §7.14 IMG-01, IMG-05).
enum ImageColumn { tags, id, size, created, use, update }

/// Which images the Images sub-tab lists (IMG-01, IMG-05): every one,
/// those no container uses, the dangling ones, which have no tag, or
/// those with an update.
enum ImageFilter { all, unused, dangling, updates }

/// The tag `docker images` prints as `<none>:<none>`, which names no tag.
const _untagged = '<none>:<none>';

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

/// One image the tab lists, with how many containers use it and what
/// the update check said of its tags.
final class ImageEntry {
  const ImageEntry(this.image, this.containers, {this.updates = const []});

  final ImageSummary image;

  /// How many containers use [image], or null when unknown
  /// ([imageContainerCount]).
  final int? containers;

  /// The update check's rows for [image]'s tags, in tag order; empty
  /// until one was checked (IMG-05).
  final List<ImageUpdateRow> updates;

  List<String> get tags => imageTagsOf(image);

  bool get dangling => image.isDangling;

  /// Whether no container uses [image]; false while unknown.
  bool get unused => containers == 0;

  /// What the check says of [image] as a whole, or null before any of
  /// its tags was checked: an update on any tag, else undecided when any
  /// tag is, else current.
  ImageUpdateStatus? get update {
    if (updates.isEmpty) return null;

    final statuses = {for (final row in updates) row.comparison.status};
    if (statuses.contains(ImageUpdateStatus.updateAvailable)) {
      return ImageUpdateStatus.updateAvailable;
    }
    if (statuses.contains(ImageUpdateStatus.unknown)) {
      return ImageUpdateStatus.unknown;
    }
    return ImageUpdateStatus.upToDate;
  }
}

/// [images] as the tab lists them: those [filter] and [terms] keep, in
/// the engine's order, each with its use counted from [containers] when
/// one was read and its tags' rows from [updates], by tag.
List<ImageEntry> imageEntries(
  List<ImageSummary> images, {
  required List<ContainerSummary>? containers,
  required ImageFilter filter,
  required List<String> terms,
  Map<String, ImageUpdateRow> updates = const {},
}) {
  final byImage = containers == null ? null : containersByImage(containers);
  return [
    for (final image in images)
      if (ImageEntry(
            image,
            imageContainerCount(image, byImage),
            updates: [for (final tag in imageTagsOf(image)) ?updates[tag]],
          )
          case final entry
          when _kept(entry, filter) && imageMatches(image, terms))
        entry,
  ];
}

bool _kept(ImageEntry entry, ImageFilter filter) => switch (filter) {
  ImageFilter.all => true,
  ImageFilter.unused => entry.unused,
  ImageFilter.dangling => entry.dangling,
  ImageFilter.updates => entry.update == ImageUpdateStatus.updateAvailable,
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

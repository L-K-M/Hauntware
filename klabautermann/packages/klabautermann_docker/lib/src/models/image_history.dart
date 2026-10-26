import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../time.dart';

/// One layer of `GET /images/{name}/history` (03 §7.14 IMG-04), newest
/// first as the daemon lists them. [createdBy] is the instruction that
/// made the layer, which can carry build arguments: callers mask it
/// before it crosses (02 IMG-04).
@immutable
final class ImageHistoryEntry {
  const ImageHistoryEntry({
    this.id,
    this.created,
    this.createdBy = '',
    this.size,
    this.comment,
    this.tags = const [],
  });

  /// The image id, or null for an intermediate layer the daemon names
  /// `<missing>`, built elsewhere and pulled without its config.
  final String? id;
  final DateTime? created;
  final String createdBy;
  final int? size;
  final String? comment;
  final List<String> tags;

  static ImageHistoryEntry parse(JsonReader r) {
    final id = r.string('Id');
    final comment = r.string('Comment');
    return ImageHistoryEntry(
      id: id == null || id == '<missing>' ? null : id,
      created: dateTimeFromUnix(r.integer('Created')),
      createdBy: r.string('CreatedBy') ?? '',
      size: r.integer('Size'),
      comment: comment == null || comment.isEmpty ? null : comment,
      tags: [
        for (final tag in r.list('Tags') ?? const [])
          if (tag is String && tag != '<none>:<none>') tag,
      ],
    );
  }
}

/// Parses an image history response; never throws.
DockerParseResult<List<ImageHistoryEntry>> parseImageHistory(Object? decoded) {
  final warnings = <String>[];
  if (decoded is! List) {
    warnings.add('image history is not a JSON array');
    return DockerParseResult(const <ImageHistoryEntry>[], warnings);
  }
  final out = <ImageHistoryEntry>[];
  for (final e in decoded) {
    if (e is Map) {
      out.add(ImageHistoryEntry.parse(JsonReader(asStringMap(e), warnings)));
    } else {
      warnings.add('image history entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}

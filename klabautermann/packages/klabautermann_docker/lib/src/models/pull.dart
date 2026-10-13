import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';

/// `progressDetail` of a pull progress message (03 §5.6, §7.14 IMG-03).
@immutable
final class ProgressDetail {
  const ProgressDetail({this.current, this.total});

  final int? current;
  final int? total;

  /// Fraction complete in `0..1`, or null when the total is unknown.
  double? get ratio {
    final c = current;
    final t = total;
    if (c == null || t == null || t <= 0) return null;
    return (c / t).clamp(0.0, 1.0);
  }

  static ProgressDetail? parse(JsonReader r) {
    final current = r.integer('current');
    final total = r.integer('total');
    if (current == null && total == null) return null;
    return ProgressDetail(current: current, total: total);
  }
}

/// One `POST /images/create` progress message (03 §7.14 IMG-03). The
/// legacy `progress`/`error` strings are deprecated but still sent by
/// older daemons, so both shapes are kept.
@immutable
final class PullProgress {
  const PullProgress({
    this.id,
    this.status,
    this.progressDetail,
    this.progress,
    this.error,
    this.errorDetail,
  });

  /// The layer id, when the message is about one layer.
  final String? id;

  /// `Pulling fs layer`, `Downloading`, `Extracting`, `Pull complete`, ...
  final String? status;
  final ProgressDetail? progressDetail;

  /// Legacy human-readable progress text.
  final String? progress;

  /// Legacy error string.
  final String? error;

  /// `errorDetail.message`.
  final String? errorDetail;

  /// True when the message reports a failure.
  bool get isError => error != null || errorDetail != null;

  static PullProgress parse(JsonReader r) {
    final detail = r.map('progressDetail');
    final errorDetail = r.map('errorDetail');
    return PullProgress(
      id: r.string('id'),
      status: r.string('status'),
      progressDetail: detail == null
          ? null
          : ProgressDetail.parse(JsonReader(detail, r.warnings)),
      progress: r.string('progress'),
      error: r.string('error'),
      errorDetail: errorDetail == null
          ? null
          : JsonReader(errorDetail, r.warnings).string('message'),
    );
  }
}

/// Parses one pull progress value; never throws.
DockerParseResult<PullProgress> parsePullProgress(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(PullProgress(), [
      'pull progress value is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(PullProgress.parse(r), r.warnings);
}

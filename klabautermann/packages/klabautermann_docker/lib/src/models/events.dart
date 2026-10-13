import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../log_time.dart';

/// One engine event from `GET /events` (03 §5.6, §7.12 DKE-02). API 1.52
/// removed the legacy `status`, `id` and `from` fields; below it they are
/// still present and duplicate `Action`, `Actor.ID` and the image. Both
/// shapes are accepted.
@immutable
final class DockerEvent {
  const DockerEvent({
    required this.type,
    required this.action,
    this.actorId,
    this.attributes = const {},
    this.scope,
    this.time,
    this.timeNano,
    this.legacyStatus,
    this.legacyId,
    this.legacyFrom,
  });

  /// `container`, `image`, `volume`, `network`, `daemon`, ...
  final String type;

  /// `start`, `die`, `health_status`, `pull`, `create`, ...
  final String action;

  /// `Actor.ID` (or the legacy `id`).
  final String? actorId;

  /// `Actor.Attributes`, including `name`, `image` and `exitCode`.
  final Map<String, String> attributes;
  final String? scope;

  /// Unix seconds from `time`.
  final int? time;

  /// Nanoseconds from `timeNano`.
  final int? timeNano;

  /// Legacy `status` field (pre-1.52 only).
  final String? legacyStatus;

  /// Legacy `id` field (pre-1.52 only).
  final String? legacyId;

  /// Legacy `from` field (pre-1.52 only), the image name.
  final String? legacyFrom;

  /// True when the daemon sent the pre-1.52 legacy fields.
  bool get isLegacy =>
      legacyStatus != null || legacyId != null || legacyFrom != null;

  /// The full timestamp with nanoseconds, when `time` is present. The
  /// daemon's `timeNano` is Unix time in nanoseconds, not a sub-second
  /// fraction, so the seconds are subtracted out.
  LogTimestamp? get timestamp {
    final t = time;
    if (t == null) return null;
    final nano = timeNano;
    if (nano == null) return LogTimestamp.fromUnix(t);
    final fraction = nano - t * 1000000000;
    return LogTimestamp.fromUnix(t, nanos: fraction);
  }

  /// `Actor.Attributes["name"]`.
  String? get name => attributes['name'];

  /// `Actor.Attributes["image"]`, falling back to the legacy `from`.
  String? get image => attributes['image'] ?? legacyFrom;

  /// `Actor.Attributes["exitCode"]` when it parses.
  int? get exitCode => int.tryParse(attributes['exitCode'] ?? '');

  static DockerEvent parse(JsonReader r, {required bool expectEventV2}) {
    final actor = r.map('Actor');
    final attributes = actor == null
        ? const <String, String>{}
        : JsonReader(actor, r.warnings).stringMap('Attributes');
    final actorId = actor == null
        ? null
        : JsonReader(actor, r.warnings).string('ID');
    final legacyStatus = r.string('status');
    final legacyId = r.string('id');
    final legacyFrom = r.string('from');
    final hasLegacy =
        legacyStatus != null || legacyId != null || legacyFrom != null;
    if (expectEventV2 && hasLegacy) {
      r.warnings.add(
        'event carries pre-1.52 legacy fields on an event-v2 connection',
      );
    }
    final action = r.string('Action') ?? legacyStatus ?? '';
    return DockerEvent(
      type: r.string('Type') ?? '',
      action: action,
      actorId: actorId ?? legacyId,
      attributes: attributes,
      scope: r.string('scope'),
      time: r.integer('time'),
      timeNano: r.integer('timeNano'),
      legacyStatus: legacyStatus,
      legacyId: legacyId,
      legacyFrom: legacyFrom,
    );
  }
}

/// Parses one `GET /events` line (03 §5.6); never throws.
DockerParseResult<DockerEvent> parseDockerEvent(
  Object? decoded, {
  bool expectEventV2 = true,
}) {
  if (decoded is! Map) {
    return const DockerParseResult(DockerEvent(type: '', action: ''), [
      'event is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(
    DockerEvent.parse(r, expectEventV2: expectEventV2),
    r.warnings,
  );
}

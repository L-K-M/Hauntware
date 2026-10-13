import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../masking.dart';
import '../time.dart';

/// One volume as `GET /volumes` reports it (03 §7.15 VOL-01).
@immutable
final class VolumeSummary {
  const VolumeSummary({
    required this.name,
    this.driver,
    this.mountpoint,
    this.scope,
    this.createdAt,
    this.labels = const {},
    this.options = const {},
  });

  final String name;
  final String? driver;
  final String? mountpoint;
  final String? scope;
  final DateTime? createdAt;
  final Map<String, MaskedValue> labels;
  final Map<String, String> options;

  static VolumeSummary parse(JsonReader r) => VolumeSummary(
    name: r.string('Name') ?? '',
    driver: r.string('Driver'),
    mountpoint: r.string('Mountpoint'),
    scope: r.string('Scope'),
    createdAt: dateTimeFromString(r.string('CreatedAt')),
    labels: maskedLabels(r.stringMap('Labels')),
    options: r.stringMap('Options'),
  );
}

/// Parses a `GET /volumes` document: `{Volumes: [...], Warnings: [...]}`
/// (03 §7.15 VOL-01). Never throws; a bare array is also accepted.
DockerParseResult<List<VolumeSummary>> parseVolumeSummaries(Object? decoded) {
  final warnings = <String>[];
  Object? list;
  if (decoded is Map) {
    final r = JsonReader(asStringMap(decoded), warnings);
    list = r.list('Volumes');
    for (final w in r.stringList('Warnings')) {
      warnings.add('volume list warning: $w');
    }
  } else if (decoded is List) {
    list = decoded;
  }
  if (list is! List) {
    warnings.add('volume list is not a JSON array');
    return DockerParseResult(const <VolumeSummary>[], warnings);
  }
  final out = <VolumeSummary>[];
  for (final e in list) {
    if (e is Map) {
      out.add(VolumeSummary.parse(JsonReader(asStringMap(e), warnings)));
    } else {
      warnings.add('volume list entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}

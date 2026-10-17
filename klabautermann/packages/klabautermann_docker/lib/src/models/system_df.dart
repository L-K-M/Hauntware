import 'package:meta/meta.dart';

import '../api_version.dart';
import '../docker_parse_result.dart';
import '../json_reader.dart';

/// The object types `GET /system/df?type=` accepts. The parameter exists
/// from API 1.42; older daemons ignore it and report every type.
enum SystemDfType {
  container('container'),
  image('image'),
  volume('volume'),
  buildCache('build-cache');

  const SystemDfType(this.wireName);

  /// The `type` query value.
  final String wireName;
}

/// One object type's disk usage from `GET /system/df` (03 §7.1 OV-05).
/// Sizes are bytes. A field is null when the daemon left it out or sent
/// it in the wrong shape.
@immutable
final class DiskUsageTotals {
  const DiskUsageTotals({
    this.totalCount,
    this.activeCount,
    this.totalSize,
    this.reclaimable,
  });

  final int? totalCount;

  /// Objects in use: running, paused or restarting containers, images
  /// with containers, referenced volumes, build cache records in use.
  final int? activeCount;
  final int? totalSize;

  /// Bytes that removing the unused objects of this type would free.
  final int? reclaimable;
}

/// `GET /system/df` reduced to per-type totals (03 §5.8, §7.1 OV-05).
/// A type is null when the response did not cover it, for example under
/// a `type` filter. The per-object lists are not kept: the summary card
/// needs totals only.
@immutable
final class SystemDf {
  const SystemDf({this.images, this.containers, this.volumes, this.buildCache});

  final DiskUsageTotals? images;
  final DiskUsageTotals? containers;
  final DiskUsageTotals? volumes;
  final DiskUsageTotals? buildCache;

  /// Reclaimable bytes summed over the types that report them; null when
  /// none does, so "unknown" never reads as zero.
  int? get reclaimable {
    int? total;
    for (final t in [images, containers, volumes, buildCache]) {
      final r = t?.reclaimable;
      if (r != null) total = (total ?? 0) + r;
    }
    return total;
  }
}

/// Parses a decoded `GET /system/df` document for the negotiated [shape]
/// (03 §5.8); never throws.
///
/// From 1.52 the daemon sends per-type totals, with the reclaimable space
/// it computed, in `ImageUsage`, `ContainerUsage`, `VolumeUsage` and
/// `BuildCacheUsage`. The 1.52 changelog spells them `ImagesUsage` and so
/// on; the spec and moby's `api/types/system/disk_usage.go` use the
/// singular names, which is what daemons send. Below 1.52 only the legacy
/// lists exist, and the totals are computed from them as moby's
/// `daemon/disk_usage.go` computes the 1.52 totals.
///
/// 1.52 sends both shapes. The 1.52 notes say 1.53 drops the legacy
/// lists, but moby's master branch still sends them unless `verbose` is
/// set, so both newer shapes are read alike: the usage objects win, and
/// a type that has only a legacy list falls back to it with a warning.
DockerParseResult<SystemDf> parseSystemDf(
  Object? decoded, {
  required SystemDfShape shape,
}) {
  if (decoded is! Map) {
    return const DockerParseResult(SystemDf(), [
      '/system/df document is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));

  DiskUsageTotals? pick(String usageKey, DiskUsageTotals? Function() legacy) {
    if (shape == SystemDfShape.legacy) return legacy();
    final usage = r.map(usageKey);
    if (usage != null) return _usageTotals(JsonReader(usage, r.warnings));
    final fallback = legacy();
    if (fallback != null) {
      r.warnings.add('$usageKey missing at API 1.52+; read the legacy list');
    }
    return fallback;
  }

  final df = SystemDf(
    images: pick('ImageUsage', () => _legacyImages(r)),
    containers: pick('ContainerUsage', () => _legacyContainers(r)),
    volumes: pick('VolumeUsage', () => _legacyVolumes(r)),
    buildCache: pick('BuildCacheUsage', () => _legacyBuildCache(r)),
  );
  return DockerParseResult(df, r.warnings);
}

DiskUsageTotals _usageTotals(JsonReader u) => DiskUsageTotals(
  totalCount: u.integer('TotalCount'),
  activeCount: u.integer('ActiveCount'),
  totalSize: u.integer('TotalSize'),
  reclaimable: u.integer('Reclaimable'),
);

/// The object entries of legacy list [key], or null when it is absent.
List<JsonReader>? _legacyEntries(JsonReader r, String key) {
  final list = r.list(key);
  if (list == null) return null;
  final out = <JsonReader>[];
  for (final e in list) {
    if (e is Map) {
      out.add(JsonReader(asStringMap(e), r.warnings));
    } else {
      r.warnings.add('$key entry is not an object');
    }
  }
  return out;
}

// The legacy reductions below mirror moby's own 1.52 totals, so a daemon
// reads the same before and after the shape gate. Unknown sizes (-1) and
// unknown container counts are never counted as reclaimable.

DiskUsageTotals? _legacyImages(JsonReader r) {
  final images = _legacyEntries(r, 'Images');
  if (images == null) return null;
  var active = 0;
  var reclaimable = 0;
  for (final i in images) {
    final containers = i.integer('Containers') ?? -1;
    final size = i.integer('Size') ?? -1;
    final shared = i.integer('SharedSize') ?? -1;
    if (containers > 0) {
      active++;
    } else if (containers == 0 && size != -1 && shared != -1) {
      reclaimable += size - shared;
    }
  }
  return DiskUsageTotals(
    totalCount: images.length,
    activeCount: active,
    totalSize: r.integer('LayersSize'),
    reclaimable: reclaimable,
  );
}

DiskUsageTotals? _legacyContainers(JsonReader r) {
  final containers = _legacyEntries(r, 'Containers');
  if (containers == null) return null;
  var active = 0;
  var total = 0;
  var reclaimable = 0;
  for (final c in containers) {
    final sizeRw = c.integer('SizeRw') ?? 0;
    total += sizeRw;
    switch (c.string('State')) {
      case 'running' || 'paused' || 'restarting':
        active++;
      default:
        reclaimable += sizeRw;
    }
  }
  return DiskUsageTotals(
    totalCount: containers.length,
    activeCount: active,
    totalSize: total,
    reclaimable: reclaimable,
  );
}

DiskUsageTotals? _legacyVolumes(JsonReader r) {
  final volumes = _legacyEntries(r, 'Volumes');
  if (volumes == null) return null;
  var active = 0;
  var total = 0;
  var reclaimable = 0;
  for (final v in volumes) {
    final usage = JsonReader(v.mapOrEmpty('UsageData'), r.warnings);
    final size = usage.integer('Size') ?? -1;
    if (size == -1) {
      active++;
      continue;
    }
    total += size;
    if (usage.integer('RefCount') == 0) {
      reclaimable += size;
    } else {
      active++;
    }
  }
  return DiskUsageTotals(
    totalCount: volumes.length,
    activeCount: active,
    totalSize: total,
    reclaimable: reclaimable,
  );
}

DiskUsageTotals? _legacyBuildCache(JsonReader r) {
  final records = _legacyEntries(r, 'BuildCache');
  if (records == null) return null;
  var active = 0;
  var total = 0;
  var reclaimable = 0;
  for (final b in records) {
    final size = b.integer('Size') ?? 0;
    final inUse = b.boolean('InUse') ?? false;
    total += size;
    if (inUse) active++;
    if (!inUse && !(b.boolean('Shared') ?? false)) reclaimable += size;
  }
  return DiskUsageTotals(
    totalCount: records.length,
    activeCount: active,
    totalSize: total,
    reclaimable: reclaimable,
  );
}

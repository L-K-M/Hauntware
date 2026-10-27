import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';
import '../masking.dart';
import '../time.dart';
import 'container.dart' show EnvVar, parseEnv;

/// One image as `GET /images/json` reports it (03 §7.14 IMG-01). The
/// `Containers` count exists from API 1.51, so it is null below the gate.
@immutable
final class ImageSummary {
  const ImageSummary({
    required this.id,
    this.parentId,
    this.repoTags = const [],
    this.repoDigests = const [],
    this.created,
    this.size,
    this.virtualSize,
    this.sharedSize,
    this.containers,
    this.labels = const {},
  });

  final String id;
  final String? parentId;
  final List<String> repoTags;
  final List<String> repoDigests;
  final DateTime? created;
  final int? size;
  final int? virtualSize;
  final int? sharedSize;

  /// In-use container count; null below API 1.51 (03 §5.8, §7.14).
  final int? containers;
  final Map<String, MaskedValue> labels;

  /// True when the image has no tag or only the `<none>` placeholder.
  bool get isDangling =>
      repoTags.isEmpty || repoTags.every((t) => t == '<none>:<none>');

  /// True when [containers] is a known, positive count.
  bool get inUse => (containers ?? 0) > 0;

  static ImageSummary parse(
    JsonReader r, {
    required bool includeContainerCount,
  }) => ImageSummary(
    id: r.string('Id') ?? '',
    parentId: r.string('ParentId'),
    repoTags: r.stringList('RepoTags'),
    repoDigests: r.stringList('RepoDigests'),
    created: dateTimeFromUnix(r.integer('Created')),
    size: r.integer('Size'),
    virtualSize: r.integer('VirtualSize'),
    sharedSize: r.integer('SharedSize'),
    containers: includeContainerCount ? r.integer('Containers') : null,
    labels: maskedLabels(r.stringMap('Labels')),
  );
}

/// Parses the `GET /images/json` array (03 §7.14 IMG-01); never throws.
/// [includeContainerCount] is the `apiVersionImageContainers` gate of
/// 03 §5.8.
DockerParseResult<List<ImageSummary>> parseImageSummaries(
  Object? decoded, {
  bool includeContainerCount = true,
}) {
  final warnings = <String>[];
  if (decoded is! List) {
    warnings.add('image list is not a JSON array');
    return DockerParseResult(const <ImageSummary>[], warnings);
  }
  final out = <ImageSummary>[];
  for (final e in decoded) {
    if (e is Map) {
      out.add(
        ImageSummary.parse(
          JsonReader(asStringMap(e), warnings),
          includeContainerCount: includeContainerCount,
        ),
      );
    } else {
      warnings.add('image list entry is not an object');
    }
  }
  return DockerParseResult(out, warnings);
}

/// Inspect `Config` of an image; `Env` and `Labels` are masked (03 §8.9).
@immutable
final class ImageConfig {
  const ImageConfig({
    this.user,
    this.workingDir,
    this.stopSignal,
    this.env = const [],
    this.cmd = const [],
    this.entrypoint = const [],
    this.exposedPorts = const [],
    this.labels = const {},
  });

  final String? user;
  final String? workingDir;
  final String? stopSignal;
  final List<EnvVar> env;
  final List<String> cmd;
  final List<String> entrypoint;
  final List<String> exposedPorts;
  final Map<String, MaskedValue> labels;

  static ImageConfig parse(JsonReader r) => ImageConfig(
    user: r.string('User'),
    workingDir: r.string('WorkingDir'),
    stopSignal: r.string('StopSignal'),
    env: parseEnv(r.stringList('Env')),
    cmd: r.stringList('Cmd'),
    entrypoint: r.stringList('Entrypoint'),
    exposedPorts: r.map('ExposedPorts')?.keys.toList() ?? const [],
    labels: maskedLabels(r.stringMap('Labels')),
  );
}

/// One inspected image (`GET /images/{name}/json`, 03 §7.14 IMG-01,
/// IMG-04). No raw JSON is kept for the same masking reason as
/// [ContainerInspect].
@immutable
final class ImageInspect {
  const ImageInspect({
    required this.id,
    this.repoTags = const [],
    this.repoDigests = const [],
    this.parent,
    this.comment,
    this.author,
    this.created,
    this.architecture,
    this.os,
    this.variant,
    this.size,
    this.config,
    this.descriptorDigest,
    this.availableChildDigests = const [],
  });

  final String id;
  final List<String> repoTags;
  final List<String> repoDigests;

  /// `Descriptor.digest` on the containerd image store: the digest the
  /// image was pulled by, often an index (D68). Null on the classic store.
  final String? descriptorDigest;

  /// The digests of the index children present locally, from `Manifests`
  /// when the inspect asked for `manifests=1` (API 1.48, D68): image
  /// manifests only, attestations left out.
  final List<String> availableChildDigests;
  final String? parent;
  final String? comment;
  final String? author;
  final DateTime? created;
  final String? architecture;
  final String? os;
  final String? variant;
  final int? size;
  final ImageConfig? config;

  /// The first `repo@sha256:...` entry for [repository], or null.
  String? digestFor(String repository) {
    for (final d in repoDigests) {
      final at = d.indexOf('@');
      if (at > 0 && d.substring(0, at) == repository) {
        return d.substring(at + 1);
      }
    }
    return null;
  }

  static ImageInspect parse(JsonReader r) {
    final config = r.map('Config');
    final descriptor = r.map('Descriptor');
    return ImageInspect(
      id: r.string('Id') ?? '',
      repoTags: r.stringList('RepoTags'),
      repoDigests: r.stringList('RepoDigests'),
      parent: r.string('Parent'),
      comment: r.string('Comment'),
      author: r.string('Author'),
      created: dateTimeFromString(r.string('Created')),
      architecture: r.string('Architecture'),
      os: r.string('Os'),
      variant: r.string('Variant'),
      size: r.integer('Size'),
      config: config == null
          ? null
          : ImageConfig.parse(JsonReader(config, r.warnings)),
      descriptorDigest: descriptor == null
          ? null
          : JsonReader(descriptor, r.warnings).string('digest'),
      availableChildDigests: [
        for (final entry in r.list('Manifests') ?? const <Object?>[])
          if (entry is Map) ?_availableImageChild(asStringMap(entry)),
      ],
    );
  }
}

/// One `Manifests` entry's digest when it is an image present locally.
String? _availableImageChild(Map<String, Object?> entry) {
  if (entry['Kind'] != 'image' || entry['Available'] != true) return null;
  final descriptor = entry['Descriptor'];
  if (descriptor is! Map) return null;
  final digest = descriptor['digest'];
  return digest is String ? digest : null;
}

/// Parses one `GET /images/{name}/json` document; never throws.
DockerParseResult<ImageInspect> parseImageInspect(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(ImageInspect(id: ''), [
      'image inspect is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(ImageInspect.parse(r), r.warnings);
}

/// What `GET /distribution/{name}/json` says the registry holds for a
/// reference (03 §7.14 IMG-05's last resort, D68): the descriptor of the
/// manifest the tag names, an index for a multi-platform tag.
@immutable
final class DistributionDescriptor {
  const DistributionDescriptor({this.digest, this.mediaType});

  final String? digest;
  final String? mediaType;
}

/// Parses one `GET /distribution/{name}/json` document; never throws.
DockerParseResult<DistributionDescriptor> parseDistributionInspect(
  Object? decoded,
) {
  if (decoded is! Map) {
    return const DockerParseResult(DistributionDescriptor(), [
      'distribution inspect is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  final descriptor = r.map('Descriptor');
  if (descriptor == null) {
    return DockerParseResult(const DistributionDescriptor(), [
      ...r.warnings,
      'distribution inspect has no Descriptor',
    ]);
  }
  final d = JsonReader(descriptor, r.warnings);
  return DockerParseResult(
    DistributionDescriptor(
      digest: d.string('digest'),
      mediaType: d.string('mediaType'),
    ),
    r.warnings,
  );
}

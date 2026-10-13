import 'package:meta/meta.dart';

import 'docker_parse_result.dart';
import 'http_types.dart';

/// A registry `HEAD /v2/<repo>/manifests/<tag>` result (03 §7.14
/// IMG-05). The digest comes from the `Docker-Content-Digest` header; the
/// request is run on the host (`curl -sI`) after the anonymous token flow
/// so it does not count against Docker Hub pull limits.
@immutable
final class RegistryManifestHead {
  const RegistryManifestHead({
    required this.statusCode,
    this.digest,
    this.mediaType,
  });

  final int statusCode;

  /// `Docker-Content-Digest`, e.g. `sha256:...`.
  final String? digest;

  /// `Content-Type`, e.g. `application/vnd.oci.image.index.v1+json`.
  final String? mediaType;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Parses a registry `HEAD` response into [RegistryManifestHead]; never
/// throws. A missing `Docker-Content-Digest` is a warning, not an error.
DockerParseResult<RegistryManifestHead> parseRegistryHead({
  required int statusCode,
  required HttpHeaders headers,
}) {
  final warnings = <String>[];
  final digest = headers.value('Docker-Content-Digest');
  if (digest == null && statusCode >= 200 && statusCode < 300) {
    warnings.add('registry HEAD returned no Docker-Content-Digest header');
  }
  final mediaType = headers.value('Content-Type');
  return DockerParseResult(
    RegistryManifestHead(
      statusCode: statusCode,
      digest: digest?.trim(),
      mediaType: mediaType,
    ),
    warnings,
  );
}

/// The verdict of an update check (03 §7.14 IMG-05).
enum ImageUpdateStatus { upToDate, updateAvailable, unknown }

/// One `repo@digest` split (03 §7.14 IMG-05).
@immutable
final class RepoDigest {
  const RepoDigest(this.repository, this.digest);

  final String repository;
  final String digest;

  /// Splits `repo@sha256:...`; returns null when there is no `@`.
  static RepoDigest? tryParse(String text) {
    final at = text.indexOf('@');
    if (at <= 0 || at == text.length - 1) return null;
    return RepoDigest(text.substring(0, at), text.substring(at + 1));
  }
}

/// The result of comparing an image's local digests with a registry HEAD
/// (03 §7.14 IMG-05). All fields are pure values; nothing is cached here.
@immutable
final class ImageDigestComparison {
  const ImageDigestComparison({
    required this.status,
    required this.repository,
    this.tag,
    this.localDigest,
    this.remoteDigest,
    this.warnings = const [],
  });

  final ImageUpdateStatus status;
  final String repository;
  final String? tag;

  /// The matching local digest, when one matched the registry.
  final String? localDigest;

  /// The registry digest, when the HEAD reported one.
  final String? remoteDigest;
  final List<String> warnings;

  bool get hasUpdate => status == ImageUpdateStatus.updateAvailable;
}

/// Compares the local `RepoDigests` of an image against a registry HEAD
/// result (03 §7.14 IMG-05). Pure: the caller supplies the local digests
/// and the already-parsed HEAD.
///
/// The containerd image store may report an index digest locally while
/// the registry HEAD returns a manifest digest (or the reverse); that
/// case is reported as a warning on an [ImageUpdateStatus.unknown] result
/// rather than a false update.
ImageDigestComparison compareImageDigest({
  required List<String> repoDigests,
  required String repository,
  String? tag,
  required RegistryManifestHead? remote,
}) {
  final warnings = <String>[];
  final local = <String>[];
  for (final d in repoDigests) {
    final parsed = RepoDigest.tryParse(d);
    if (parsed == null) {
      warnings.add('unparseable RepoDigest $d');
      continue;
    }
    if (parsed.repository == repository) local.add(parsed.digest);
  }

  if (remote == null) {
    warnings.add('no registry HEAD result for $repository');
    return ImageDigestComparison(
      status: ImageUpdateStatus.unknown,
      repository: repository,
      tag: tag,
      warnings: warnings,
    );
  }
  final remoteDigest = remote.digest;
  if (remoteDigest == null) {
    warnings.add('registry HEAD for $repository carried no digest');
    return ImageDigestComparison(
      status: ImageUpdateStatus.unknown,
      repository: repository,
      tag: tag,
      warnings: warnings,
    );
  }
  if (local.isEmpty) {
    warnings.add('no local RepoDigests for $repository');
    return ImageDigestComparison(
      status: ImageUpdateStatus.unknown,
      repository: repository,
      tag: tag,
      remoteDigest: remoteDigest,
      warnings: warnings,
    );
  }
  for (final d in local) {
    if (d == remoteDigest) {
      return ImageDigestComparison(
        status: ImageUpdateStatus.upToDate,
        repository: repository,
        tag: tag,
        localDigest: d,
        remoteDigest: remoteDigest,
      );
    }
  }
  // An index/manifest mismatch looks like an update but is not; report it
  // as unknown so the caller does not show a false amber indicator.
  if (_looksLikeIndexMismatch(remote.mediaType, local, remoteDigest)) {
    warnings.add(
      'local and registry digests differ but the media type is an index; '
      'containerd store comparison is unverified (03 §7.14)',
    );
    return ImageDigestComparison(
      status: ImageUpdateStatus.unknown,
      repository: repository,
      tag: tag,
      localDigest: local.first,
      remoteDigest: remoteDigest,
      warnings: warnings,
    );
  }
  return ImageDigestComparison(
    status: ImageUpdateStatus.updateAvailable,
    repository: repository,
    tag: tag,
    localDigest: local.first,
    remoteDigest: remoteDigest,
  );
}

bool _looksLikeIndexMismatch(
  String? mediaType,
  List<String> local,
  String remoteDigest,
) =>
    mediaType != null &&
    mediaType.contains('index') &&
    !local.contains(remoteDigest);

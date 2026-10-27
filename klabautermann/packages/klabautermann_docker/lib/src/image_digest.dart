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

/// Why an update check could not decide (03 §7.14 IMG-05, D68).
enum ImageUpdateIssue {
  /// No registry answer to compare with.
  noResult,

  /// The registry wants credentials (`401`): a private registry, read
  /// through the host CLI instead.
  unauthorized,

  /// The registry does not know the repository or tag (`404`).
  notFound,

  /// The source address has spent its quota (`429`).
  rateLimited,

  /// Any other non-success status.
  failed,

  /// The registry answered without `Docker-Content-Digest`.
  noDigest,

  /// The image has no local digest for the repository, e.g. it was built
  /// on the host and never pulled or pushed.
  noLocalDigest,
}

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
    this.issue,
    this.localDigest,
    this.remoteDigest,
  });

  final ImageUpdateStatus status;
  final String repository;
  final String? tag;

  /// Set exactly when [status] is [ImageUpdateStatus.unknown].
  final ImageUpdateIssue? issue;

  /// The matching local digest, or the one the registry no longer has.
  final String? localDigest;

  /// The registry digest, when the HEAD reported one.
  final String? remoteDigest;

  bool get hasUpdate => status == ImageUpdateStatus.updateAvailable;
}

/// Compares an image's local digests with a registry HEAD result (03
/// §7.14 IMG-05, D68). Pure: the caller supplies the local digests and
/// the parsed HEAD.
///
/// The tag is current when the registry digest equals one of:
/// - the `RepoDigests` entry for [repository] (its familiar name);
/// - [descriptorDigest], the image's `Descriptor` on the containerd
///   store;
/// - one of [availableChildDigests], the index children present locally
///   (`GET /images/{name}/json?manifests=1`, API 1.48). A push from the
///   containerd store with only some platforms stores a platform's
///   manifest while `RepoDigests` keeps the index digest, so without
///   this a pushed image would always read as updated.
///
/// Older daemons give only the first two, which is enough on the classic
/// store, where a push records the pushed digest.
ImageDigestComparison compareImageDigest({
  required List<String> repoDigests,
  required String repository,
  String? tag,
  required RegistryManifestHead? remote,
  String? descriptorDigest,
  List<String> availableChildDigests = const [],
}) {
  ImageDigestComparison unknown(ImageUpdateIssue issue, {String? remote}) =>
      ImageDigestComparison(
        status: ImageUpdateStatus.unknown,
        repository: repository,
        tag: tag,
        issue: issue,
        remoteDigest: remote,
      );

  if (remote == null) return unknown(ImageUpdateIssue.noResult);
  if (!remote.isSuccess) {
    return unknown(switch (remote.statusCode) {
      401 || 403 => ImageUpdateIssue.unauthorized,
      404 => ImageUpdateIssue.notFound,
      429 => ImageUpdateIssue.rateLimited,
      _ => ImageUpdateIssue.failed,
    });
  }
  final remoteDigest = remote.digest;
  if (remoteDigest == null) return unknown(ImageUpdateIssue.noDigest);

  final named = [
    for (final d in repoDigests)
      if (RepoDigest.tryParse(d) case final parsed?
          when parsed.repository == repository)
        parsed.digest,
  ];
  final local = {...named, ?descriptorDigest};
  if (local.isEmpty) {
    return unknown(ImageUpdateIssue.noLocalDigest, remote: remoteDigest);
  }
  if (local.contains(remoteDigest) ||
      availableChildDigests.contains(remoteDigest)) {
    return ImageDigestComparison(
      status: ImageUpdateStatus.upToDate,
      repository: repository,
      tag: tag,
      localDigest: remoteDigest,
      remoteDigest: remoteDigest,
    );
  }
  return ImageDigestComparison(
    status: ImageUpdateStatus.updateAvailable,
    repository: repository,
    tag: tag,
    localDigest: named.firstOrNull ?? descriptorDigest,
    remoteDigest: remoteDigest,
  );
}

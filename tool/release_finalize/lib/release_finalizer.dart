import 'dart:io';

/// Whether the remote bundle must contain a detached checksum signature.
enum ReleaseSignaturePolicy { required }

enum ReleaseVisibilityExpectation { draft, published }

enum ReleaseVerificationStatus {
  valid,
  integrityMismatch,
  policyMismatch,
  inconclusive,
}

/// A fresh verification of the assets currently attached to a release.
final class ReleaseVerification {
  final ReleaseVerificationStatus status;
  final String detail;

  const ReleaseVerification.valid()
    : status = ReleaseVerificationStatus.valid,
      detail = '';

  const ReleaseVerification.integrityMismatch(this.detail)
    : status = ReleaseVerificationStatus.integrityMismatch;

  const ReleaseVerification.policyMismatch(this.detail)
    : status = ReleaseVerificationStatus.policyMismatch;

  const ReleaseVerification.inconclusive(this.detail)
    : status = ReleaseVerificationStatus.inconclusive;
}

final class VerifiedReleaseTag {
  final String tag;
  final String commit;

  const VerifiedReleaseTag({required this.tag, required this.commit});
}

/// The downloaded, still-hidden release that the maintainer will audit.
final class ReleaseCandidate {
  final String identity;
  final String tag;
  final String sourceCommit;
  final Directory directory;
  final File checksums;

  const ReleaseCandidate({
    required this.identity,
    required this.tag,
    required this.sourceCommit,
    required this.directory,
    required this.checksums,
  });
}

enum ReleasePublicationStatus { draft, published, inconclusive }

final class ReleasePublicationState {
  final ReleasePublicationStatus status;
  final String detail;

  const ReleasePublicationState.draft()
    : status = ReleasePublicationStatus.draft,
      detail = '';

  const ReleasePublicationState.published()
    : status = ReleasePublicationStatus.published,
      detail = '';

  const ReleasePublicationState.inconclusive(this.detail)
    : status = ReleasePublicationStatus.inconclusive;
}

abstract interface class ReleaseRepository {
  /// Downloads one draft and rejects an existing signature or malformed set.
  Future<ReleaseCandidate> downloadUnsignedDraft({
    required String tag,
    required String expectedSourceCommit,
    required Directory destination,
  });

  /// Uploads without replacing an existing asset.
  Future<void> uploadSignature({
    required ReleaseCandidate candidate,
    required File signature,
  });

  /// Re-fetches every asset before checking sums and signature.
  Future<ReleaseVerification> verify({
    required ReleaseCandidate candidate,
    required ReleaseVisibilityExpectation visibility,
    required ReleaseSignaturePolicy signaturePolicy,
  });

  Future<void> publish(ReleaseCandidate candidate);

  /// Reconciles a publish request whose response may not reflect its outcome.
  Future<ReleasePublicationState> readPublication(ReleaseCandidate candidate);
}

abstract interface class ReleaseSignatureService {
  Future<VerifiedReleaseTag> verifyTag({
    required String tag,
    required String expectedFingerprint,
  });

  Future<File> signChecksums({
    required File checksums,
    required String expectedFingerprint,
  });

  Future<void> verifyChecksumSignature({
    required File checksums,
    required File signature,
    required String expectedFingerprint,
  });
}

/// Performs the human machine's independent build and downloaded-app smoke.
abstract interface class LocalReleaseAuditor {
  Future<void> compareLocalBuild(ReleaseCandidate candidate);

  Future<void> smokeDownloadedBuild(ReleaseCandidate candidate);
}

abstract interface class ReleaseAlertSink {
  Future<void> alert(String message);
}

enum ReleaseFinalizationStatus {
  published,
  draftMismatch,
  draftInconclusive,
  publishedInconclusive,
}

final class ReleaseFinalizationResult {
  final ReleaseFinalizationStatus status;
  final String detail;

  const ReleaseFinalizationResult(this.status, [this.detail = '']);
}

/// Signs and publishes only after both local and freshly downloaded checks.
final class ReleaseFinalizer {
  final ReleaseRepository _repository;
  final ReleaseSignatureService _signatures;
  final LocalReleaseAuditor _localAuditor;
  final ReleaseAlertSink _alerts;

  factory ReleaseFinalizer({
    required ReleaseRepository repository,
    required ReleaseSignatureService signatures,
    required LocalReleaseAuditor localAuditor,
    required ReleaseAlertSink alerts,
  }) {
    return ReleaseFinalizer._(repository, signatures, localAuditor, alerts);
  }

  const ReleaseFinalizer._(
    this._repository,
    this._signatures,
    this._localAuditor,
    this._alerts,
  );

  Future<ReleaseFinalizationResult> finalize({
    required String tag,
    required String expectedFingerprint,
    required Directory workingDirectory,
  }) async {
    final initialTag = await _signatures.verifyTag(
      tag: tag,
      expectedFingerprint: expectedFingerprint,
    );
    final candidate = await _repository.downloadUnsignedDraft(
      tag: tag,
      expectedSourceCommit: initialTag.commit,
      destination: workingDirectory,
    );
    final sourceCheck = _checkSource(candidate, initialTag);
    if (sourceCheck != null) return _leaveDraft(sourceCheck);

    await _localAuditor.compareLocalBuild(candidate);
    await _localAuditor.smokeDownloadedBuild(candidate);

    // Re-check the mutable tag immediately before the maintainer signs.
    final signingTag = await _signatures.verifyTag(
      tag: tag,
      expectedFingerprint: expectedFingerprint,
    );
    final signingSourceCheck = _checkSource(candidate, signingTag);
    if (signingSourceCheck != null) return _leaveDraft(signingSourceCheck);

    final signature = await _signatures.signChecksums(
      checksums: candidate.checksums,
      expectedFingerprint: expectedFingerprint,
    );
    await _signatures.verifyChecksumSignature(
      checksums: candidate.checksums,
      signature: signature,
      expectedFingerprint: expectedFingerprint,
    );
    await _repository.uploadSignature(
      candidate: candidate,
      signature: signature,
    );

    final draftVerification = await _verifyTwice(
      candidate,
      ReleaseVisibilityExpectation.draft,
    );
    if (draftVerification.status != ReleaseVerificationStatus.valid) {
      return _leaveDraft(draftVerification);
    }

    final publication = await _publishAndReconcile(candidate);
    if (publication.status != ReleasePublicationStatus.published) {
      return _keepPossiblyPublished(candidate.tag, publication.detail);
    }

    final liveVerification = await _verifyTwice(
      candidate,
      ReleaseVisibilityExpectation.published,
    );
    if (liveVerification.status == ReleaseVerificationStatus.valid) {
      return const ReleaseFinalizationResult(
        ReleaseFinalizationStatus.published,
      );
    }
    if (liveVerification.status !=
        ReleaseVerificationStatus.integrityMismatch) {
      return _keepPossiblyPublished(candidate.tag, liveVerification.detail);
    }

    // GitHub cannot bind DELETE to a prior ETag, so removal stays manual.
    return _keepPossiblyPublished(
      candidate.tag,
      'repeated live integrity mismatch; manual removal required: '
      '${liveVerification.detail}',
    );
  }

  ReleaseVerification? _checkSource(
    ReleaseCandidate candidate,
    VerifiedReleaseTag tag,
  ) {
    if (candidate.tag == tag.tag &&
        candidate.sourceCommit.toLowerCase() == tag.commit.toLowerCase()) {
      return null;
    }

    return ReleaseVerification.policyMismatch(
      'draft source ${candidate.sourceCommit} no longer matches signed '
      '${candidate.tag} at ${tag.commit}',
    );
  }

  Future<ReleasePublicationState> _publishAndReconcile(
    ReleaseCandidate candidate,
  ) async {
    Object? publishFailure;
    try {
      await _repository.publish(candidate);
    } on Object catch (error) {
      publishFailure = error;
    }

    final first = await _readPublication(candidate);
    if (first.status == ReleasePublicationStatus.published) return first;

    final second = await _readPublication(candidate);
    if (second.status == ReleasePublicationStatus.published) return second;

    final details = <String>{
      if (publishFailure != null) 'publish response: $publishFailure',
      if (first.detail.isNotEmpty) first.detail,
      if (second.detail.isNotEmpty) second.detail,
      if (first.status == ReleasePublicationStatus.draft &&
          second.status == ReleasePublicationStatus.draft)
        'GitHub still reports the release as draft after publication',
    };
    return ReleasePublicationState.inconclusive(details.join('; '));
  }

  Future<ReleasePublicationState> _readPublication(
    ReleaseCandidate candidate,
  ) async {
    try {
      return await _repository.readPublication(candidate);
    } on Object catch (error) {
      return ReleasePublicationState.inconclusive(
        'publication state could not be confirmed: $error',
      );
    }
  }

  Future<ReleaseVerification> _verifyTwice(
    ReleaseCandidate candidate,
    ReleaseVisibilityExpectation visibility,
  ) async {
    final first = await _verifyOnce(candidate, visibility);
    if (first.status == ReleaseVerificationStatus.valid) return first;

    final second = await _verifyOnce(candidate, visibility);
    if (second.status == ReleaseVerificationStatus.valid) return second;
    if (first.status == second.status &&
        second.status != ReleaseVerificationStatus.inconclusive) {
      return second;
    }

    final details = <String>{first.detail, second.detail}
      ..removeWhere((detail) => detail.isEmpty);
    return ReleaseVerification.inconclusive(details.join('; '));
  }

  Future<ReleaseVerification> _verifyOnce(
    ReleaseCandidate candidate,
    ReleaseVisibilityExpectation visibility,
  ) async {
    try {
      return await _repository.verify(
        candidate: candidate,
        visibility: visibility,
        signaturePolicy: ReleaseSignaturePolicy.required,
      );
    } on Object catch (error) {
      return ReleaseVerification.inconclusive('verification failed: $error');
    }
  }

  Future<ReleaseFinalizationResult> _leaveDraft(
    ReleaseVerification verification,
  ) async {
    final status = verification.status == ReleaseVerificationStatus.inconclusive
        ? ReleaseFinalizationStatus.draftInconclusive
        : ReleaseFinalizationStatus.draftMismatch;
    await _alerts.alert('Release remains drafted: ${verification.detail}');

    return ReleaseFinalizationResult(status, verification.detail);
  }

  Future<ReleaseFinalizationResult> _keepPossiblyPublished(
    String tag,
    String detail,
  ) async {
    final message = detail.isEmpty ? 'verification is inconclusive' : detail;
    await _alerts.alert(
      '$tag may be published and requires human review: $message',
    );
    return ReleaseFinalizationResult(
      ReleaseFinalizationStatus.publishedInconclusive,
      message,
    );
  }
}

// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:test/test.dart';

import '../lib/release_finalizer.dart';

const _tag = 'v0.1.0';
const _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _replacementCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fingerprint = '0123456789ABCDEF0123456789ABCDEF01234567';
const _identity = '71';

void main() {
  late Directory sandbox;
  late _FakeRepository repository;
  late _FakeSignatureService signatures;
  late _FakeLocalAuditor auditor;
  late _FakeAlertSink alerts;
  late ReleaseFinalizer finalizer;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-finalizer-test-',
    );
    repository = _FakeRepository(sandbox);
    signatures = _FakeSignatureService(sandbox);
    auditor = _FakeLocalAuditor();
    alerts = _FakeAlertSink();
    finalizer = ReleaseFinalizer(
      repository: repository,
      signatures: signatures,
      localAuditor: auditor,
      alerts: alerts,
    );
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'signs only after local audit, then publishes a verified draft',
    () async {
      repository.verifications.addAll(const [
        ReleaseVerification.valid(),
        ReleaseVerification.valid(),
      ]);

      final result = await _finalize(finalizer, sandbox);

      expect(result.status, ReleaseFinalizationStatus.published);
      expect(repository.calls, [
        'download:$_tag:$_commit',
        'upload:SHA256SUMS.asc',
        'verify:draft:required',
        'publish:$_tag',
        'publication:$_tag',
        'verify:published:required',
      ]);
      expect(signatures.calls, [
        'verify-tag:$_tag',
        'verify-tag:$_tag',
        'sign:SHA256SUMS',
        'verify-signature:SHA256SUMS.asc',
      ]);
      expect(auditor.calls, ['audit:$_tag', 'smoke:$_tag']);
      expect(alerts.messages, isEmpty);
      expect(signatures.signSequence, greaterThan(auditor.smokeSequence));
    },
  );

  test('leaves the draft when an integrity mismatch repeats', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.integrityMismatch('bad digest'),
      ReleaseVerification.integrityMismatch('bad digest'),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.draftMismatch);
    expect(repository.published, isFalse);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('bad digest'));
  });

  test('leaves the draft when verification remains inconclusive', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.inconclusive('GitHub unavailable'),
      ReleaseVerification.inconclusive('GitHub unavailable'),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.draftInconclusive);
    expect(repository.published, isFalse);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('GitHub unavailable'));
  });

  test('keeps a live mismatch for manual removal', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.valid(),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.integrityMismatch('asset changed'),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.published, isTrue);
    expect(repository.deleted, isFalse);
    expect(alerts.messages, hasLength(1));
    expect(alerts.messages.single, contains('manual removal'));
  });

  test('never deletes a live release for a policy mismatch', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.valid(),
      ReleaseVerification.policyMismatch('visibility is stale'),
      ReleaseVerification.policyMismatch('visibility is stale'),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('visibility is stale'));
  });

  test('alerts when live verification throws twice', () async {
    repository.verifications.add(const ReleaseVerification.valid());
    repository.verificationFailureCalls.addAll({1, 2});

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('verification failed'));
  });

  test('keeps the release when it recovers before deletion', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.valid(),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.valid(),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('human review'));
  });

  test('reconciles a publish response lost after GitHub applied it', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.valid(),
      ReleaseVerification.valid(),
    ]);
    repository.publishFailureAfterMutation = StateError('connection lost');

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.published);
    expect(repository.deleted, isFalse);
    expect(repository.calls, contains('publication:$_tag'));
  });

  test('alerts when publication cannot be reconciled', () async {
    repository.verifications.add(const ReleaseVerification.valid());
    repository.publicationStates.addAll(const [
      ReleasePublicationState.draft(),
      ReleasePublicationState.draft(),
    ]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.deleted, isFalse);
    expect(alerts.messages.single, contains('human review'));
  });

  test('never invokes an unsafe automatic deletion', () async {
    repository.verifications.addAll(const [
      ReleaseVerification.valid(),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.integrityMismatch('asset changed'),
      ReleaseVerification.integrityMismatch('asset changed'),
    ]);
    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.publishedInconclusive);
    expect(repository.deleted, isFalse);
    expect(alerts.messages, hasLength(1));
    expect(alerts.messages.single, contains('manual removal'));
  });

  test('halts when the signed tag moves before signing', () async {
    signatures.tagCommits.addAll([_commit, _replacementCommit]);

    final result = await _finalize(finalizer, sandbox);

    expect(result.status, ReleaseFinalizationStatus.draftMismatch);
    expect(repository.calls, ['download:$_tag:$_commit']);
    expect(signatures.calls, ['verify-tag:$_tag', 'verify-tag:$_tag']);
    expect(alerts.messages.single, contains(_replacementCommit));
  });

  test('does not upload when local rehearsal fails', () async {
    auditor.failure = StateError('local smoke failed');

    await expectLater(
      _finalize(finalizer, sandbox),
      throwsA(isA<StateError>()),
    );

    expect(repository.calls, ['download:$_tag:$_commit']);
    expect(signatures.calls, ['verify-tag:$_tag']);
  });
}

Future<ReleaseFinalizationResult> _finalize(
  ReleaseFinalizer finalizer,
  Directory sandbox,
) {
  return finalizer.finalize(
    tag: _tag,
    expectedFingerprint: _fingerprint,
    workingDirectory: sandbox,
  );
}

final class _FakeRepository implements ReleaseRepository {
  final Directory root;
  final List<String> calls = [];
  final List<ReleaseVerification> verifications = [];
  final List<ReleasePublicationState> publicationStates = [];
  bool published = false;
  Object? publishFailureAfterMutation;
  final Set<int> verificationFailureCalls = {};
  var _verificationCall = 0;

  _FakeRepository(this.root);

  @override
  Future<ReleaseCandidate> downloadUnsignedDraft({
    required String tag,
    required String expectedSourceCommit,
    required Directory destination,
  }) async {
    calls.add('download:$tag:$expectedSourceCommit');
    final sums = File('${root.path}/SHA256SUMS')
      ..writeAsStringSync('digest  artifact\n');

    return ReleaseCandidate(
      identity: _identity,
      tag: tag,
      sourceCommit: expectedSourceCommit,
      directory: root,
      checksums: sums,
    );
  }

  @override
  Future<void> uploadSignature({
    required ReleaseCandidate candidate,
    required File signature,
  }) async {
    calls.add('upload:${signature.uri.pathSegments.last}');
  }

  @override
  Future<ReleaseVerification> verify({
    required ReleaseCandidate candidate,
    required ReleaseVisibilityExpectation visibility,
    required ReleaseSignaturePolicy signaturePolicy,
  }) async {
    calls.add('verify:${visibility.name}:${signaturePolicy.name}');
    final call = _verificationCall++;
    if (verificationFailureCalls.contains(call)) {
      throw StateError('verification failed');
    }
    return verifications.removeAt(0);
  }

  @override
  Future<void> publish(ReleaseCandidate candidate) async {
    calls.add('publish:${candidate.tag}');
    published = true;
    if (publishFailureAfterMutation case final failure?) throw failure;
  }

  @override
  Future<ReleasePublicationState> readPublication(
    ReleaseCandidate candidate,
  ) async {
    calls.add('publication:${candidate.tag}');
    if (publicationStates.isNotEmpty) return publicationStates.removeAt(0);

    return published
        ? const ReleasePublicationState.published()
        : const ReleasePublicationState.draft();
  }

  bool get deleted => calls.any((call) => call.startsWith('delete:'));
}

final class _FakeSignatureService implements ReleaseSignatureService {
  final Directory root;
  final List<String> calls = [];
  final List<String> tagCommits = [];
  int signSequence = -1;

  _FakeSignatureService(this.root);

  @override
  Future<VerifiedReleaseTag> verifyTag({
    required String tag,
    required String expectedFingerprint,
  }) async {
    calls.add('verify-tag:$tag');
    final commit = tagCommits.isEmpty ? _commit : tagCommits.removeAt(0);
    return VerifiedReleaseTag(tag: tag, commit: commit);
  }

  @override
  Future<File> signChecksums({
    required File checksums,
    required String expectedFingerprint,
  }) async {
    calls.add('sign:${checksums.uri.pathSegments.last}');
    signSequence = _nextSequence();
    return File('${root.path}/SHA256SUMS.asc')..writeAsStringSync('signature');
  }

  @override
  Future<void> verifyChecksumSignature({
    required File checksums,
    required File signature,
    required String expectedFingerprint,
  }) async {
    calls.add('verify-signature:${signature.uri.pathSegments.last}');
  }
}

final class _FakeLocalAuditor implements LocalReleaseAuditor {
  final List<String> calls = [];
  Object? failure;
  int smokeSequence = -1;

  @override
  Future<void> compareLocalBuild(ReleaseCandidate candidate) async {
    calls.add('audit:${candidate.tag}');
    if (failure case final error?) throw error;
  }

  @override
  Future<void> smokeDownloadedBuild(ReleaseCandidate candidate) async {
    calls.add('smoke:${candidate.tag}');
    if (failure case final error?) throw error;
    smokeSequence = _nextSequence();
  }
}

final class _FakeAlertSink implements ReleaseAlertSink {
  final List<String> messages = [];

  @override
  Future<void> alert(String message) async {
    messages.add(message);
  }
}

int _sequence = 0;
int _nextSequence() => _sequence++;

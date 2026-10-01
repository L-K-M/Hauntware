// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports, prefer_initializing_formals

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../release_support/lib/release_artifacts.dart';
import '../../release_version/lib/release_version.dart';
import 'release_finalizer.dart';
import 'release_process.dart';

const String _githubExecutable = 'gh';
const String _githubUploadsOrigin = 'https://uploads.github.com';
const String _gitExecutable = 'git';
const String _gpgExecutable = 'gpg';
const double _artifactSizeTolerance = 0.10;
const Duration _launchObservation = Duration(seconds: 5);
const String _signatureArmor = '-----BEGIN PGP SIGNATURE-----';

final RegExp _fingerprintPattern = RegExp(r'^[0-9A-Fa-f]{40}$');
final RegExp _commitPattern = RegExp(r'^[0-9A-Fa-f]{40}$');
final RegExp _repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

enum ReleaseFinalizeFailureKind {
  integrityMismatch,
  policyMismatch,
  inconclusive,
}

final class ReleaseFinalizeException implements Exception {
  final ReleaseFinalizeFailureKind kind;
  final String message;

  const ReleaseFinalizeException.integrityMismatch(this.message)
    : kind = ReleaseFinalizeFailureKind.integrityMismatch;

  const ReleaseFinalizeException.policyMismatch(this.message)
    : kind = ReleaseFinalizeFailureKind.policyMismatch;

  const ReleaseFinalizeException.inconclusive(this.message)
    : kind = ReleaseFinalizeFailureKind.inconclusive;

  @override
  String toString() => message;
}

String validateOpenPgpFingerprint(String value) {
  if (!_fingerprintPattern.hasMatch(value)) {
    throw const FormatException(
      'expected fingerprint must contain exactly 40 hexadecimal characters',
    );
  }

  return value.toUpperCase();
}

/// Uses local Git/GPG verification and compares it with GitHub's exact tag.
final class GitGpgReleaseSignatureService implements ReleaseSignatureService {
  final String _repository;
  final Directory _repositoryRoot;
  final ReleaseProcessRunner _runner;

  GitGpgReleaseSignatureService({
    required String repository,
    required Directory repositoryRoot,
  }) : this.withRunner(
         repository: repository,
         repositoryRoot: repositoryRoot,
         runner: const IoReleaseProcessRunner(),
       );

  GitGpgReleaseSignatureService.withRunner({
    required String repository,
    required Directory repositoryRoot,
    required ReleaseProcessRunner runner,
  }) : _repository = _validateRepository(repository),
       _repositoryRoot = repositoryRoot.absolute,
       _runner = runner;

  @override
  Future<VerifiedReleaseTag> verifyTag({
    required String tag,
    required String expectedFingerprint,
  }) async {
    _validateTag(tag);
    final fingerprint = validateOpenPgpFingerprint(expectedFingerprint);
    final type = await _runText(
      _gitExecutable,
      ['cat-file', '-t', 'refs/tags/$tag'],
      workingDirectory: _repositoryRoot,
      operation: 'read local tag type',
    );
    if (type.trim() != 'tag') {
      throw ReleaseFinalizeException.policyMismatch(
        'local $tag is not an annotated OpenPGP-signed tag',
      );
    }

    final localObject = _requireCommit(
      (await _runText(
        _gitExecutable,
        ['rev-parse', '--verify', 'refs/tags/$tag'],
        workingDirectory: _repositoryRoot,
        operation: 'resolve local tag object',
      )).trim(),
      'local tag object',
    );
    final localCommit = _requireCommit(
      (await _runText(
        _gitExecutable,
        ['rev-parse', '--verify', 'refs/tags/$tag^{commit}'],
        workingDirectory: _repositoryRoot,
        operation: 'resolve local tag commit',
      )).trim(),
      'local tag commit',
    );
    final verification = await _run(
      _gitExecutable,
      ['verify-tag', '--raw', tag],
      workingDirectory: _repositoryRoot,
      operation: 'verify local tag signature',
    );
    if (verification.exitCode != 0) {
      throw ReleaseFinalizeException.policyMismatch(
        'local tag signature verification failed: '
        '${_diagnostic(verification)}',
      );
    }
    _requireExpectedSigner(
      '${verification.standardOutput}\n${verification.standardError}',
      fingerprint,
      subject: 'tag $tag',
      mismatchKind: ReleaseFinalizeFailureKind.policyMismatch,
    );

    final remoteReference = _asMap(
      await _runJson([
        'api',
        'repos/$_repository/git/ref/tags/${Uri.encodeComponent(tag)}',
      ], operation: 'read remote tag reference'),
      'remote tag reference',
    );
    final remoteTarget = _asMap(
      remoteReference['object'],
      'remote tag reference target',
    );
    if (_asString(remoteTarget['type'], 'remote tag target type') != 'tag') {
      throw ReleaseFinalizeException.policyMismatch(
        'remote $tag is not an annotated tag',
      );
    }
    final remoteObject = _requireCommit(
      _asString(remoteTarget['sha'], 'remote tag object'),
      'remote tag object',
    );
    if (remoteObject.toLowerCase() != localObject.toLowerCase()) {
      throw ReleaseFinalizeException.policyMismatch(
        'local and remote $tag objects differ',
      );
    }

    final remoteTag = _asMap(
      await _runJson([
        'api',
        'repos/$_repository/git/tags/$remoteObject',
      ], operation: 'read remote annotated tag'),
      'remote annotated tag',
    );
    if (_asString(remoteTag['tag'], 'remote annotated tag name') != tag) {
      throw ReleaseFinalizeException.policyMismatch(
        'remote annotated tag name does not match $tag',
      );
    }
    final remoteCommitTarget = _asMap(
      remoteTag['object'],
      'remote annotated tag target',
    );
    if (_asString(remoteCommitTarget['type'], 'remote tag object type') !=
        'commit') {
      throw ReleaseFinalizeException.policyMismatch(
        'remote $tag does not point directly to a commit',
      );
    }
    final remoteCommit = _requireCommit(
      _asString(remoteCommitTarget['sha'], 'remote tag commit'),
      'remote tag commit',
    );
    if (remoteCommit.toLowerCase() != localCommit.toLowerCase()) {
      throw ReleaseFinalizeException.policyMismatch(
        'local and remote $tag commits differ',
      );
    }

    return VerifiedReleaseTag(tag: tag, commit: localCommit.toLowerCase());
  }

  @override
  Future<File> signChecksums({
    required File checksums,
    required String expectedFingerprint,
  }) async {
    final fingerprint = validateOpenPgpFingerprint(expectedFingerprint);
    _requireNonemptyFile(checksums, kReleaseChecksumFileName);
    final signature = File(
      p.join(checksums.parent.path, kReleaseSignatureFileName),
    );
    if (signature.existsSync()) {
      throw const ReleaseFinalizeException.policyMismatch(
        'refusing to overwrite an existing SHA256SUMS.asc',
      );
    }

    await _runSuccessful(_gpgExecutable, [
      '--batch',
      '--armor',
      '--detach-sign',
      '--local-user',
      fingerprint,
      '--output',
      signature.path,
      checksums.path,
    ], operation: 'sign SHA256SUMS');
    _requireArmoredSignature(signature);

    return signature;
  }

  @override
  Future<void> verifyChecksumSignature({
    required File checksums,
    required File signature,
    required String expectedFingerprint,
  }) async {
    final fingerprint = validateOpenPgpFingerprint(expectedFingerprint);
    _requireNonemptyFile(
      checksums,
      kReleaseChecksumFileName,
      failureKind: ReleaseFinalizeFailureKind.integrityMismatch,
    );
    _requireArmoredSignature(
      signature,
      failureKind: ReleaseFinalizeFailureKind.integrityMismatch,
    );
    final verification = await _run(_gpgExecutable, [
      '--batch',
      '--status-fd=1',
      '--verify',
      signature.path,
      checksums.path,
    ], operation: 'verify SHA256SUMS signature');
    if (verification.exitCode != 0) {
      final status =
          '${verification.standardOutput}\n${verification.standardError}';
      if (status.contains('[GNUPG:] BADSIG')) {
        throw ReleaseFinalizeException.integrityMismatch(
          'SHA256SUMS signature is invalid: ${_diagnostic(verification)}',
        );
      }

      throw ReleaseFinalizeException.inconclusive(
        'could not verify SHA256SUMS signature: '
        '${_diagnostic(verification)}',
      );
    }
    _requireExpectedSigner(
      '${verification.standardOutput}\n${verification.standardError}',
      fingerprint,
      subject: kReleaseSignatureFileName,
      mismatchKind: ReleaseFinalizeFailureKind.integrityMismatch,
    );
  }

  Future<Object?> _runJson(
    List<String> arguments, {
    required String operation,
  }) async {
    final output = await _runText(
      _githubExecutable,
      arguments,
      operation: operation,
    );
    try {
      return jsonDecode(output);
    } on FormatException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        '$operation returned invalid JSON: $error',
      );
    }
  }

  Future<String> _runText(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    final result = await _run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      operation: operation,
    );
    if (result.exitCode == 0) return result.standardOutput;

    throw ReleaseFinalizeException.inconclusive(
      '$operation failed (${result.exitCode}): ${_diagnostic(result)}',
    );
  }

  Future<void> _runSuccessful(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    await _runText(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      operation: operation,
    );
  }

  Future<ReleaseProcessResult> _run(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    try {
      return await _runner.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        '$operation could not start: ${error.message}',
      );
    }
  }
}

enum _ReleaseAudience { prerelease, stable }

/// Reads and mutates one exact GitHub release without name-based overwrite.
final class GhReleaseRepository implements ReleaseRepository {
  final String _repository;
  final ReleaseSignatureService _signatures;
  final String _expectedFingerprint;
  final ReleaseProcessRunner _runner;
  int? _pinnedReleaseId;
  String? _pinnedTag;

  GhReleaseRepository({
    required String repository,
    required ReleaseSignatureService signatures,
    required String expectedFingerprint,
  }) : this.withRunner(
         repository: repository,
         signatures: signatures,
         expectedFingerprint: expectedFingerprint,
         runner: const IoReleaseProcessRunner(),
       );

  GhReleaseRepository.withRunner({
    required String repository,
    required ReleaseSignatureService signatures,
    required String expectedFingerprint,
    required ReleaseProcessRunner runner,
  }) : _repository = _validateRepository(repository),
       _signatures = signatures,
       _expectedFingerprint = validateOpenPgpFingerprint(expectedFingerprint),
       _runner = runner;

  @override
  Future<ReleaseCandidate> downloadUnsignedDraft({
    required String tag,
    required String expectedSourceCommit,
    required Directory destination,
  }) async {
    final expected = _artifactManifest(tag);
    final sourceCommit = _requireCommit(
      expectedSourceCommit,
      'expected source commit',
    ).toLowerCase();
    _requireEmptyDestination(destination);
    final snapshot = await _readOneByTag(tag);
    _requireVisibility(snapshot, ReleaseVisibilityExpectation.draft);
    _requireAssetSet(snapshot, expected.unsignedNames);
    _pinnedReleaseId = snapshot.id;
    _pinnedTag = tag;
    await _download(snapshot, destination);
    await _verifyPayloads(
      destination,
      expected,
      notes: snapshot.notes,
      tag: tag,
      sourceCommit: sourceCommit,
    );

    return ReleaseCandidate(
      identity: snapshot.id.toString(),
      tag: tag,
      sourceCommit: sourceCommit,
      directory: destination,
      checksums: File(p.join(destination.path, kReleaseChecksumFileName)),
    );
  }

  @override
  Future<void> uploadSignature({
    required ReleaseCandidate candidate,
    required File signature,
  }) async {
    if (p.basename(signature.path) != kReleaseSignatureFileName) {
      throw const ReleaseFinalizeException.policyMismatch(
        'signature asset must be named SHA256SUMS.asc',
      );
    }
    _requireArmoredSignature(
      signature,
      failureKind: ReleaseFinalizeFailureKind.policyMismatch,
    );
    _requireCandidate(candidate);
    await _requireCurrentSource(candidate);
    final expected = _artifactManifest(candidate.tag);
    final snapshot = await _readPinned(candidate);
    _requireVisibility(snapshot, ReleaseVisibilityExpectation.draft);
    _requireAssetSet(snapshot, expected.unsignedNames);

    final result = await _run(_githubExecutable, [
      'api',
      '--method',
      'POST',
      '-H',
      'Content-Type: application/pgp-signature',
      '--input',
      signature.path,
      '$_githubUploadsOrigin/repos/$_repository/releases/${snapshot.id}/'
          'assets?name=${Uri.encodeQueryComponent(kReleaseSignatureFileName)}',
    ], operation: 'upload $kReleaseSignatureFileName');
    if (result.exitCode != 0) {
      throw ReleaseFinalizeException.inconclusive(
        'signature upload failed (${result.exitCode}): '
        '${_diagnostic(result)}',
      );
    }
  }

  @override
  Future<ReleaseVerification> verify({
    required ReleaseCandidate candidate,
    required ReleaseVisibilityExpectation visibility,
    required ReleaseSignaturePolicy signaturePolicy,
  }) async {
    Directory? destination;
    _RemoteRelease? snapshot;
    try {
      if (signaturePolicy != ReleaseSignaturePolicy.required) {
        throw const ReleaseFinalizeException.policyMismatch(
          'unsupported release signature policy',
        );
      }
      _requireCandidate(candidate);
      await _requireCurrentSource(candidate);
      final expected = _artifactManifest(candidate.tag);
      snapshot = await _readPinned(candidate);
      _requireVisibility(snapshot, visibility);
      _requireAssetSet(snapshot, expected.signedNames);
      destination = Directory.systemTemp.createTempSync(
        'poltergeist-release-verify-',
      );
      await _download(snapshot, destination);
      await _verifyPayloads(
        destination,
        expected,
        notes: snapshot.notes,
        tag: candidate.tag,
        sourceCommit: candidate.sourceCommit,
      );
      await _signatures.verifyChecksumSignature(
        checksums: File(p.join(destination.path, kReleaseChecksumFileName)),
        signature: File(p.join(destination.path, kReleaseSignatureFileName)),
        expectedFingerprint: _expectedFingerprint,
      );

      return const ReleaseVerification.valid();
    } on ReleaseFinalizeException catch (error) {
      return switch (error.kind) {
        ReleaseFinalizeFailureKind.integrityMismatch when snapshot != null =>
          ReleaseVerification.integrityMismatch(error.message),
        ReleaseFinalizeFailureKind.integrityMismatch =>
          ReleaseVerification.inconclusive(error.message),
        ReleaseFinalizeFailureKind.policyMismatch =>
          ReleaseVerification.policyMismatch(error.message),
        ReleaseFinalizeFailureKind.inconclusive =>
          ReleaseVerification.inconclusive(error.message),
      };
    } on FileSystemException catch (error) {
      return ReleaseVerification.inconclusive(error.message);
    } on ProcessException catch (error) {
      return ReleaseVerification.inconclusive(error.message);
    } finally {
      if (destination?.existsSync() ?? false) {
        destination!.deleteSync(recursive: true);
      }
    }
  }

  @override
  Future<void> publish(ReleaseCandidate candidate) async {
    _requireCandidate(candidate);
    await _requireCurrentSource(candidate);
    final snapshot = await _readPinned(candidate);
    _requireVisibility(snapshot, ReleaseVisibilityExpectation.draft);
    final result = await _run(_githubExecutable, [
      'api',
      '--method',
      'PATCH',
      '-F',
      'draft=false',
      '-f',
      'make_latest=false',
      'repos/$_repository/releases/${snapshot.id}',
    ], operation: 'publish release ${candidate.tag}');
    if (result.exitCode != 0) {
      throw ReleaseFinalizeException.inconclusive(
        'release publication failed (${result.exitCode}): '
        '${_diagnostic(result)}',
      );
    }
  }

  @override
  Future<ReleasePublicationState> readPublication(
    ReleaseCandidate candidate,
  ) async {
    final snapshot = await _readPinned(candidate);
    return switch (snapshot.visibility) {
      ReleaseVisibilityExpectation.draft =>
        const ReleasePublicationState.draft(),
      ReleaseVisibilityExpectation.published =>
        const ReleasePublicationState.published(),
    };
  }

  Future<_RemoteRelease> _readOneByTag(String tag) async {
    final result = await _run(_githubExecutable, [
      'api',
      '--paginate',
      '--slurp',
      '--method',
      'GET',
      '-f',
      'per_page=100',
      'repos/$_repository/releases',
    ], operation: 'list releases for $tag');
    if (result.exitCode != 0) {
      throw ReleaseFinalizeException.inconclusive(
        'release query failed (${result.exitCode}): ${_diagnostic(result)}',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(result.standardOutput);
    } on FormatException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        'GitHub returned invalid release JSON: $error',
      );
    }
    final matches = <_RemoteRelease>[];
    for (final pageValue in _asList(decoded, 'release pages')) {
      for (final value in _asList(pageValue, 'release page')) {
        final release = _asMap(value, 'release');
        if (_asString(release['tag_name'], 'release tag') != tag) continue;

        matches.add(_parseRelease(release));
      }
    }
    if (matches.length != 1) {
      throw ReleaseFinalizeException.policyMismatch(
        'expected exactly one release for $tag; found ${matches.length}',
      );
    }

    final snapshot = matches.single;
    final expectedAudience = _releaseAudience(tag);
    if (snapshot.audience != expectedAudience) {
      throw ReleaseFinalizeException.policyMismatch(
        'release ${snapshot.id} has the wrong prerelease state',
      );
    }

    return snapshot;
  }

  Future<_RemoteRelease> _readPinned(ReleaseCandidate candidate) async {
    _requireCandidate(candidate);
    final releaseId = _pinnedReleaseId!;
    final result = await _run(_githubExecutable, [
      'api',
      '--method',
      'GET',
      'repos/$_repository/releases/$releaseId',
    ], operation: 'read pinned release $releaseId');
    if (result.exitCode != 0) {
      throw ReleaseFinalizeException.inconclusive(
        'pinned release query failed (${result.exitCode}): '
        '${_diagnostic(result)}',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(result.standardOutput);
    } on FormatException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        'GitHub returned invalid release JSON: $error',
      );
    }
    final snapshot = _parseRelease(_asMap(decoded, 'release'));
    if (snapshot.id != releaseId || snapshot.tag != candidate.tag) {
      throw ReleaseFinalizeException.policyMismatch(
        'pinned release identity no longer matches ${candidate.tag}',
      );
    }
    if (snapshot.audience != _releaseAudience(candidate.tag)) {
      throw ReleaseFinalizeException.policyMismatch(
        'release ${snapshot.id} has the wrong prerelease state',
      );
    }

    return snapshot;
  }

  _RemoteRelease _parseRelease(Map<String, Object?> release) {
    final assets = <_RemoteAsset>[];
    for (final assetValue in _asList(release['assets'], 'release assets')) {
      final asset = _asMap(assetValue, 'release asset');
      assets.add(
        _RemoteAsset(
          id: _asPositiveInt(asset['id'], 'release asset id'),
          name: _asString(asset['name'], 'release asset name'),
          size: _asPositiveInt(asset['size'], 'release asset size'),
        ),
      );
    }

    return _RemoteRelease(
      id: _asPositiveInt(release['id'], 'release id'),
      tag: _asString(release['tag_name'], 'release tag'),
      visibility: _asBool(release['draft'], 'release draft state')
          ? ReleaseVisibilityExpectation.draft
          : ReleaseVisibilityExpectation.published,
      audience: _asBool(release['prerelease'], 'release prerelease state')
          ? _ReleaseAudience.prerelease
          : _ReleaseAudience.stable,
      notes: _asStringAllowEmpty(release['body'], 'release notes'),
      assets: assets,
    );
  }

  void _requireCandidate(ReleaseCandidate candidate) {
    if (_pinnedReleaseId?.toString() == candidate.identity &&
        _pinnedTag == candidate.tag) {
      return;
    }

    throw const ReleaseFinalizeException.policyMismatch(
      'release identity does not match the downloaded draft',
    );
  }

  Future<void> _requireCurrentSource(ReleaseCandidate candidate) async {
    final verified = await _signatures.verifyTag(
      tag: candidate.tag,
      expectedFingerprint: _expectedFingerprint,
    );
    if (verified.tag == candidate.tag &&
        verified.commit.toLowerCase() == candidate.sourceCommit.toLowerCase()) {
      return;
    }

    throw ReleaseFinalizeException.policyMismatch(
      'signed ${candidate.tag} no longer resolves to draft source '
      '${candidate.sourceCommit}',
    );
  }

  Future<void> _download(_RemoteRelease release, Directory destination) async {
    destination.createSync(recursive: true);
    final assets = [...release.assets]
      ..sort((left, right) => left.name.compareTo(right.name));
    for (final asset in assets) {
      final output = File(p.join(destination.path, asset.name));
      ReleaseProcessResult result;
      try {
        result = await _runner.runToFile(_githubExecutable, [
          'api',
          '-H',
          'Accept: application/octet-stream',
          'repos/$_repository/releases/assets/${asset.id}',
        ], output: output);
      } on ProcessException catch (error) {
        throw ReleaseFinalizeException.inconclusive(
          'download of ${asset.name} could not start: ${error.message}',
        );
      }
      if (result.exitCode != 0) {
        throw ReleaseFinalizeException.inconclusive(
          'download of ${asset.name} failed (${result.exitCode}): '
          '${_diagnostic(result)}',
        );
      }
      if (!output.existsSync() || output.lengthSync() != asset.size) {
        throw ReleaseFinalizeException.inconclusive(
          'download of ${asset.name} did not match GitHub size metadata',
        );
      }
    }
  }

  Future<void> _verifyPayloads(
    Directory directory,
    ReleaseArtifactManifest expected, {
    required String notes,
    required String tag,
    required String sourceCommit,
  }) async {
    final checksumFile = File(p.join(directory.path, kReleaseChecksumFileName));
    _requireNonemptyFile(checksumFile, kReleaseChecksumFileName);
    final checksumText = checksumFile.readAsStringSync();
    late final ReleaseChecksumManifest checksums;
    try {
      checksums = ReleaseChecksumManifest.parseCanonical(
        checksumText,
        expectedNames: expected.payloadNames,
      );
      await checksums.verifyFiles(directory);
    } on ReleaseArtifactException catch (error) {
      throw ReleaseFinalizeException.integrityMismatch(error.message);
    }
    try {
      ReleaseNotesDocument.verifyCanonical(
        notes,
        tag: tag,
        sourceCommit: sourceCommit,
        checksums: checksumText,
      );
    } on ReleaseArtifactException catch (error) {
      throw ReleaseFinalizeException.policyMismatch(error.message);
    }
  }

  Future<ReleaseProcessResult> _run(
    String executable,
    List<String> arguments, {
    required String operation,
  }) async {
    try {
      return await _runner.run(executable, arguments);
    } on ProcessException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        '$operation could not start: ${error.message}',
      );
    }
  }
}

abstract interface class PrimaryPlatformReleaseDriver {
  String get assetName;

  Future<File> buildTaggedArtifact({
    required Directory repositoryRoot,
    required String tag,
    required String sourceCommit,
    required Directory destination,
  });

  Future<void> smokeArtifact(File artifact, Directory destination);
}

enum PrimaryReleasePlatform { linuxX64, macosUniversal, windowsX64 }

/// Reproduces the CI packaging shape on the maintainer's desktop platform.
final class DesktopPrimaryPlatformReleaseDriver
    implements PrimaryPlatformReleaseDriver {
  final PrimaryReleasePlatform _platform;
  final ReleaseProcessRunner _runner;

  DesktopPrimaryPlatformReleaseDriver(PrimaryReleasePlatform platform)
    : this.withRunner(
        platform: platform,
        runner: const IoReleaseProcessRunner(),
      );

  DesktopPrimaryPlatformReleaseDriver.withRunner({
    required PrimaryReleasePlatform platform,
    required ReleaseProcessRunner runner,
  }) : _platform = platform,
       _runner = runner;

  factory DesktopPrimaryPlatformReleaseDriver.current({
    String? operatingSystem,
  }) {
    final system = operatingSystem ?? Platform.operatingSystem;
    final platform = switch (system) {
      'linux' when Abi.current() == Abi.linuxX64 =>
        PrimaryReleasePlatform.linuxX64,
      'macos' => PrimaryReleasePlatform.macosUniversal,
      'windows' when Abi.current() == Abi.windowsX64 =>
        PrimaryReleasePlatform.windowsX64,
      _ => throw UnsupportedError(
        'release finalization requires Linux, macOS, or Windows x64',
      ),
    };

    return DesktopPrimaryPlatformReleaseDriver(platform);
  }

  @override
  String get assetName => switch (_platform) {
    PrimaryReleasePlatform.linuxX64 => 'poltergeist-linux-x64.tar.gz',
    PrimaryReleasePlatform.macosUniversal => 'poltergeist-macos-universal.zip',
    PrimaryReleasePlatform.windowsX64 => 'poltergeist-windows-x64.zip',
  };

  @override
  Future<File> buildTaggedArtifact({
    required Directory repositoryRoot,
    required String tag,
    required String sourceCommit,
    required Directory destination,
  }) async {
    _validateTag(tag);
    final expectedCommit = _requireCommit(
      sourceCommit,
      'expected local-build source commit',
    );
    _requireEmptyDestination(destination);
    destination.createSync(recursive: true);
    final checkout = Directory(p.join(destination.path, 'source'));
    await _runSuccessful(_gitExecutable, [
      'clone',
      '--no-checkout',
      '--no-hardlinks',
      repositoryRoot.absolute.path,
      checkout.path,
    ], operation: 'clone tagged source');
    await _runSuccessful(
      _gitExecutable,
      ['checkout', '--detach', expectedCommit],
      workingDirectory: checkout,
      operation: 'check out $tag source commit',
    );
    final checkoutCommit = (await _runText(
      _gitExecutable,
      ['rev-parse', '--verify', 'HEAD'],
      workingDirectory: checkout,
      operation: 'resolve local build checkout',
    )).trim();
    if (expectedCommit.toLowerCase() != checkoutCommit.toLowerCase()) {
      throw ReleaseFinalizeException.policyMismatch(
        'local build checkout does not match $tag',
      );
    }

    await _runSuccessful(
      'dart',
      ['pub', 'get', '--enforce-lockfile'],
      workingDirectory: checkout,
      operation: 'resolve tagged workspace',
    );
    final app = Directory(p.join(checkout.path, 'app', 'poltergeist_app'));
    await _runSuccessful(
      'flutter',
      ['pub', 'get', '--enforce-lockfile'],
      workingDirectory: app,
      operation: 'resolve tagged Flutter app',
    );
    final trackedChanges = (await _runText(
      _gitExecutable,
      ['status', '--porcelain=v1', '--untracked-files=no'],
      workingDirectory: checkout,
      operation: 'verify tagged source cleanliness',
    )).trim();
    if (trackedChanges.isNotEmpty) {
      throw ReleaseFinalizeException.policyMismatch(
        'dependency resolution changed tracked tagged source: '
        '$trackedChanges',
      );
    }

    await _runSuccessful(
      'dart',
      ['run', 'tool/license_gate/bin/check.dart'],
      workingDirectory: checkout,
      operation: 'verify tagged Séance licenses',
    );
    await _runSuccessful(
      'flutter',
      ['build', _flutterTarget, '--release', '--no-pub'],
      workingDirectory: app,
      operation: 'build tagged $_flutterTarget client',
    );

    final output = File(p.join(destination.path, assetName));
    await _package(app, destination, output);
    _requireNonemptyFile(output, assetName);

    return output;
  }

  @override
  Future<void> smokeArtifact(File artifact, Directory destination) async {
    _requireNonemptyFile(artifact, assetName);
    _requireEmptyDestination(destination);
    destination.createSync(recursive: true);
    final executable = await _extractExecutable(artifact, destination);
    _requireNonemptyFile(executable, 'downloaded desktop executable');
    ReleaseLaunchResult result;
    try {
      result = await _runner.observeLaunch(
        executable.path,
        const [],
        observation: _launchObservation,
        workingDirectory: executable.parent,
      );
    } on ProcessException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        'downloaded client could not start: ${error.message}',
      );
    }
    if (result.status == ReleaseLaunchStatus.remainedRunning) return;

    throw ReleaseFinalizeException.policyMismatch(
      'downloaded client exited during the smoke window with code '
      '${result.exitCode}',
    );
  }

  String get _flutterTarget => switch (_platform) {
    PrimaryReleasePlatform.linuxX64 => 'linux',
    PrimaryReleasePlatform.macosUniversal => 'macos',
    PrimaryReleasePlatform.windowsX64 => 'windows',
  };

  Future<void> _package(
    Directory app,
    Directory destination,
    File output,
  ) async {
    switch (_platform) {
      case PrimaryReleasePlatform.linuxX64:
        final bundle = _findSingleDirectory(
          Directory(p.join(app.path, 'build', 'linux')),
          (directory) =>
              p.basename(directory.path) == 'bundle' &&
              p.basename(directory.parent.path) == 'release',
          label: 'Linux release bundle',
        );
        final staged = Directory(
          p.join(destination.path, 'poltergeist-linux-x64'),
        );
        bundle.renameSync(staged.path);
        await _runSuccessful('tar', [
          '-czf',
          output.path,
          '-C',
          destination.path,
          p.basename(staged.path),
        ], operation: 'package local Linux bundle');
      case PrimaryReleasePlatform.macosUniversal:
        final application = _findSingleDirectory(
          Directory(
            p.join(app.path, 'build', 'macos', 'Build', 'Products', 'Release'),
          ),
          (directory) => p.extension(directory.path) == '.app',
          label: 'macOS release application',
        );
        await _runSuccessful('ditto', [
          '-c',
          '-k',
          '--keepParent',
          application.path,
          output.path,
        ], operation: 'package local macOS application');
      case PrimaryReleasePlatform.windowsX64:
        final bundle = _findSingleDirectory(
          Directory(p.join(app.path, 'build', 'windows')),
          (directory) =>
              p.basename(directory.path) == 'Release' &&
              p.basename(directory.parent.path) == 'runner',
          label: 'Windows release bundle',
        );
        final staged = Directory(
          p.join(destination.path, 'poltergeist-windows-x64'),
        );
        bundle.renameSync(staged.path);
        await _runSuccessful(
          '7z',
          ['a', '-bd', output.path, p.basename(staged.path)],
          workingDirectory: destination,
          operation: 'package local Windows bundle',
        );
    }
  }

  Future<File> _extractExecutable(File artifact, Directory destination) async {
    switch (_platform) {
      case PrimaryReleasePlatform.linuxX64:
        await _runSuccessful('tar', [
          '-xzf',
          artifact.path,
          '-C',
          destination.path,
        ], operation: 'extract downloaded Linux bundle');
        return File(
          p.join(destination.path, 'poltergeist-linux-x64', 'poltergeist'),
        );
      case PrimaryReleasePlatform.macosUniversal:
        await _runSuccessful('ditto', [
          '-x',
          '-k',
          artifact.path,
          destination.path,
        ], operation: 'extract downloaded macOS application');
        final application = _findSingleDirectory(
          destination,
          (directory) => p.extension(directory.path) == '.app',
          label: 'downloaded macOS application',
        );
        return File(
          p.join(application.path, 'Contents', 'MacOS', 'Poltergeist'),
        );
      case PrimaryReleasePlatform.windowsX64:
        await _runSuccessful('7z', [
          'x',
          '-y',
          '-o${destination.path}',
          artifact.path,
        ], operation: 'extract downloaded Windows bundle');
        return File(
          p.join(
            destination.path,
            'poltergeist-windows-x64',
            'poltergeist_app.exe',
          ),
        );
    }
  }

  Future<String> _runText(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    final result = await _run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      operation: operation,
    );
    if (result.exitCode == 0) return result.standardOutput;

    throw ReleaseFinalizeException.inconclusive(
      '$operation failed (${result.exitCode}): ${_diagnostic(result)}',
    );
  }

  Future<void> _runSuccessful(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    await _runText(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      operation: operation,
    );
  }

  Future<ReleaseProcessResult> _run(
    String executable,
    List<String> arguments, {
    required String operation,
    Directory? workingDirectory,
  }) async {
    try {
      return await _runner.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ReleaseFinalizeException.inconclusive(
        '$operation could not start: ${error.message}',
      );
    }
  }
}

/// Applies D23's bounded comparison before running the downloaded artifact.
final class SizeComparingLocalReleaseAuditor implements LocalReleaseAuditor {
  final Directory _repositoryRoot;
  final PrimaryPlatformReleaseDriver _driver;

  SizeComparingLocalReleaseAuditor({
    required Directory repositoryRoot,
    required PrimaryPlatformReleaseDriver driver,
  }) : _repositoryRoot = repositoryRoot.absolute,
       _driver = driver;

  @override
  Future<void> compareLocalBuild(ReleaseCandidate candidate) async {
    final remote = File(p.join(candidate.directory.path, _driver.assetName));
    _requireNonemptyFile(remote, _driver.assetName);
    final sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-local-build-',
    );
    try {
      final local = await _driver.buildTaggedArtifact(
        repositoryRoot: _repositoryRoot,
        tag: candidate.tag,
        sourceCommit: candidate.sourceCommit,
        destination: Directory(p.join(sandbox.path, 'build')),
      );
      _requireNonemptyFile(local, 'local ${_driver.assetName}');
      final localSize = local.lengthSync();
      final remoteSize = remote.lengthSync();
      final difference = (remoteSize - localSize).abs() / localSize;
      if (difference <= _artifactSizeTolerance) return;

      throw ReleaseFinalizeException.policyMismatch(
        'CI ${_driver.assetName} differs from the local build by '
        '${(difference * 100).toStringAsFixed(2)}%; allowed 10.00%',
      );
    } finally {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> smokeDownloadedBuild(ReleaseCandidate candidate) async {
    final remote = File(p.join(candidate.directory.path, _driver.assetName));
    _requireNonemptyFile(remote, _driver.assetName);
    final sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-smoke-',
    );
    try {
      await _driver.smokeArtifact(
        remote,
        Directory(p.join(sandbox.path, 'extracted')),
      );
    } finally {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    }
  }
}

final class ConsoleReleaseAlertSink implements ReleaseAlertSink {
  final void Function(String message) _write;

  ConsoleReleaseAlertSink([void Function(String message)? write])
    : _write = write ?? stderr.writeln;

  @override
  Future<void> alert(String message) async {
    _write('release alert: $message');
  }
}

final class _RemoteAsset {
  final int id;
  final String name;
  final int size;

  const _RemoteAsset({
    required this.id,
    required this.name,
    required this.size,
  });
}

final class _RemoteRelease {
  final int id;
  final String tag;
  final ReleaseVisibilityExpectation visibility;
  final _ReleaseAudience audience;
  final String notes;
  final List<_RemoteAsset> assets;

  const _RemoteRelease({
    required this.id,
    required this.tag,
    required this.visibility,
    required this.audience,
    required this.notes,
    required this.assets,
  });
}

ReleaseVersion _validateTag(String tag) {
  if (!tag.startsWith('v')) {
    throw ReleaseFinalizeException.policyMismatch('invalid release tag "$tag"');
  }
  try {
    return ReleaseVersion.parse(tag.substring(1));
  } on ReleaseVersionFormatException catch (error) {
    throw ReleaseFinalizeException.policyMismatch(error.message);
  }
}

String _validateRepository(String repository) {
  if (_repositoryPattern.hasMatch(repository)) return repository;

  throw FormatException('invalid GitHub repository "$repository"');
}

String _requireCommit(String value, String label) {
  if (_commitPattern.hasMatch(value)) return value;

  throw ReleaseFinalizeException.inconclusive('$label is not a full SHA-1');
}

void _requireExpectedSigner(
  String status,
  String expectedFingerprint, {
  required String subject,
  required ReleaseFinalizeFailureKind mismatchKind,
}) {
  final signer = _primaryFingerprint(status);
  if (signer == null) {
    throw ReleaseFinalizeException.inconclusive(
      '$subject produced no OpenPGP VALIDSIG fingerprint',
    );
  }
  if (signer == expectedFingerprint) return;

  _throwFailure(
    mismatchKind,
    '$subject signer $signer does not match expected $expectedFingerprint',
  );
}

String? _primaryFingerprint(String status) {
  for (final line in const LineSplitter().convert(status)) {
    final marker = line.indexOf('[GNUPG:] VALIDSIG ');
    if (marker < 0) continue;

    final fields = line
        .substring(marker + '[GNUPG:] VALIDSIG '.length)
        .trim()
        .split(RegExp(r'\s+'));
    if (fields.isEmpty || !_fingerprintPattern.hasMatch(fields.first)) {
      continue;
    }
    final primary = fields.length >= 10 ? fields[9] : fields.first;
    if (_fingerprintPattern.hasMatch(primary)) return primary.toUpperCase();
  }

  return null;
}

Never _throwFailure(ReleaseFinalizeFailureKind kind, String message) {
  throw switch (kind) {
    ReleaseFinalizeFailureKind.integrityMismatch =>
      ReleaseFinalizeException.integrityMismatch(message),
    ReleaseFinalizeFailureKind.policyMismatch =>
      ReleaseFinalizeException.policyMismatch(message),
    ReleaseFinalizeFailureKind.inconclusive =>
      ReleaseFinalizeException.inconclusive(message),
  };
}

void _requireArmoredSignature(
  File signature, {
  ReleaseFinalizeFailureKind failureKind =
      ReleaseFinalizeFailureKind.policyMismatch,
}) {
  _requireNonemptyFile(
    signature,
    kReleaseSignatureFileName,
    failureKind: failureKind,
  );
  final prefix = signature.openSync()..setPositionSync(0);
  try {
    final bytes = prefix.readSync(_signatureArmor.length);
    if (utf8.decode(bytes, allowMalformed: true) == _signatureArmor) return;
  } finally {
    prefix.closeSync();
  }

  _throwFailure(
    failureKind,
    'SHA256SUMS.asc is not an armored OpenPGP signature',
  );
}

void _requireNonemptyFile(
  File file,
  String label, {
  ReleaseFinalizeFailureKind failureKind =
      ReleaseFinalizeFailureKind.policyMismatch,
}) {
  if (file.existsSync() && file.lengthSync() > 0) return;

  _throwFailure(failureKind, '$label is missing or empty');
}

void _requireEmptyDestination(Directory destination) {
  if (!destination.existsSync()) return;
  if (destination.listSync(followLinks: false).isEmpty) return;

  throw ReleaseFinalizeException.policyMismatch(
    'working directory is not empty: ${destination.path}',
  );
}

void _requireVisibility(
  _RemoteRelease release,
  ReleaseVisibilityExpectation expected,
) {
  if (release.visibility == expected) return;

  throw ReleaseFinalizeException.inconclusive(
    'release ${release.id} for ${release.tag} is not ${expected.name}',
  );
}

void _requireAssetSet(_RemoteRelease release, Set<String> expected) {
  final names = release.assets.map((asset) => asset.name).toList();
  final actual = names.toSet();
  final duplicates = actual.length != names.length;
  if (!duplicates &&
      actual.length == expected.length &&
      actual.containsAll(expected)) {
    return;
  }

  final unexpected = actual.difference(expected).toList()..sort();
  final missing = expected.difference(actual).toList()..sort();
  throw ReleaseFinalizeException.integrityMismatch(
    'release asset set is malformed; missing $missing, unexpected '
    '$unexpected${duplicates ? ', duplicate names present' : ''}',
  );
}

_ReleaseAudience _releaseAudience(String tag) {
  final version = _validateTag(tag);

  if (version.semantic.startsWith('0.') || tag.contains('-')) {
    return _ReleaseAudience.prerelease;
  }

  return _ReleaseAudience.stable;
}

ReleaseArtifactManifest _artifactManifest(String tag) {
  try {
    return ReleaseArtifactManifest.forTag(tag);
  } on ReleaseArtifactException catch (error) {
    throw ReleaseFinalizeException.policyMismatch(error.message);
  }
}

Directory _findSingleDirectory(
  Directory root,
  bool Function(Directory directory) matches, {
  required String label,
}) {
  if (!root.existsSync()) {
    throw ReleaseFinalizeException.policyMismatch('$label is missing');
  }
  final found = root
      .listSync(recursive: true, followLinks: false)
      .whereType<Directory>()
      .where(matches)
      .toList();
  if (found.length == 1) return found.single;

  throw ReleaseFinalizeException.policyMismatch(
    'expected one $label; found ${found.length}',
  );
}

String _diagnostic(ReleaseProcessResult result) {
  final error = result.standardError.trim();
  if (error.isNotEmpty) return error;
  final output = result.standardOutput.trim();

  return output.isEmpty ? 'no diagnostic output' : output;
}

Map<String, Object?> _asMap(Object? value, String label) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();

  throw ReleaseFinalizeException.inconclusive('$label is not a JSON object');
}

List<Object?> _asList(Object? value, String label) {
  if (value is List<Object?>) return value;
  if (value is List) return value.cast<Object?>();

  throw ReleaseFinalizeException.inconclusive('$label is not a JSON list');
}

String _asString(Object? value, String label) {
  if (value is String && value.isNotEmpty) return value;

  throw ReleaseFinalizeException.inconclusive('$label is missing or invalid');
}

String _asStringAllowEmpty(Object? value, String label) {
  if (value is String) return value;

  throw ReleaseFinalizeException.inconclusive('$label is missing or invalid');
}

int _asPositiveInt(Object? value, String label) {
  if (value is int && value > 0) return value;

  throw ReleaseFinalizeException.inconclusive('$label is missing or invalid');
}

bool _asBool(Object? value, String label) {
  if (value is bool) return value;

  throw ReleaseFinalizeException.inconclusive('$label is missing or invalid');
}

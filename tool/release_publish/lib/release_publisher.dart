// Release tools share the version grammar without entering the app graph.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../release_support/lib/release_artifacts.dart';
import '../../release_version/lib/release_version.dart';

const String _notesFileName = 'release-notes.md';
const String _openPgpRequirement = 'verified OpenPGP signature';

final RegExp _repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
final RegExp _commitPattern = RegExp(r'^[0-9a-fA-F]{40}$');

enum ReleaseSignature { verifiedOpenPgp, invalid }

enum ReleaseVisibility { draft, published }

enum ReleaseAudience { prerelease, stable }

enum LatestReleaseSelection { excluded }

final class ReleaseTagState {
  final String name;
  final String commit;
  final ReleaseSignature signature;

  const ReleaseTagState({
    required this.name,
    required this.commit,
    required this.signature,
  });
}

final class ReleaseAssetState {
  final String name;
  final int size;

  const ReleaseAssetState({required this.name, required this.size});
}

final class ReleaseState {
  final int id;
  final String tag;
  final ReleaseVisibility visibility;
  final ReleaseAudience audience;
  final List<ReleaseAssetState> assets;
  final String notes;

  const ReleaseState({
    required this.id,
    required this.tag,
    required this.visibility,
    required this.audience,
    required this.assets,
    required this.notes,
  });
}

final class CreateDraftRelease {
  final String repository;
  final String tag;
  final String title;
  final File notesFile;
  final List<File> assets;
  final ReleaseAudience audience;
  final LatestReleaseSelection latestSelection;

  const CreateDraftRelease({
    required this.repository,
    required this.tag,
    required this.title,
    required this.notesFile,
    required this.assets,
    required this.audience,
    required this.latestSelection,
  });
}

abstract interface class GitHubReleaseGateway {
  Future<ReleaseTagState> readTag({
    required String repository,
    required String tag,
  });

  Future<List<ReleaseState>> findReleases({
    required String repository,
    required String tag,
  });

  Future<void> createDraft(CreateDraftRelease request);
}

final class PublishDraftRequest {
  final String repository;
  final String tag;
  final String expectedCommit;
  final Directory artifactsDirectory;
  final Directory outputDirectory;

  const PublishDraftRequest({
    required this.repository,
    required this.tag,
    required this.expectedCommit,
    required this.artifactsDirectory,
    required this.outputDirectory,
  });
}

final class DraftReleaseReport {
  final int releaseId;
  final int payloadCount;
  final File checksumFile;
  final File notesFile;

  const DraftReleaseReport({
    required this.releaseId,
    required this.payloadCount,
    required this.checksumFile,
    required this.notesFile,
  });
}

final class ReleasePublishException implements Exception {
  final String message;

  const ReleasePublishException(this.message);

  @override
  String toString() => message;
}

/// Proves that the remote tag is the signed source selected by the workflow.
final class ReleaseSourceVerifier {
  final GitHubReleaseGateway _gateway;

  const ReleaseSourceVerifier(this._gateway);

  Future<void> verify({
    required String repository,
    required String tag,
    required String expectedCommit,
  }) async {
    _validateSourceArguments(
      repository: repository,
      tag: tag,
      expectedCommit: expectedCommit,
    );

    final remote = await _gateway.readTag(repository: repository, tag: tag);
    if (remote.name != tag) {
      throw ReleasePublishException(
        'remote tag name "${remote.name}" does not match "$tag"',
      );
    }
    if (remote.commit.toLowerCase() != expectedCommit.toLowerCase()) {
      throw ReleasePublishException(
        'remote tag $tag at ${remote.commit} does not match expected commit '
        '$expectedCommit',
      );
    }
    if (remote.signature != ReleaseSignature.verifiedOpenPgp) {
      throw ReleasePublishException(
        'remote tag $tag lacks a $_openPgpRequirement',
      );
    }
  }
}

/// Creates one hidden release only after local and remote evidence is closed.
final class DraftReleasePublisher {
  final GitHubReleaseGateway _gateway;

  const DraftReleasePublisher(this._gateway);

  Future<DraftReleaseReport> publish(PublishDraftRequest request) async {
    final version = _validateSourceArguments(
      repository: request.repository,
      tag: request.tag,
      expectedCommit: request.expectedCommit,
    );
    final manifest = ReleaseArtifactManifest.forTag(request.tag);
    final payloads = await _validatePayloads(
      request.artifactsDirectory,
      manifest.payloadNames,
    );
    _validateOutputPath(request);

    await ReleaseSourceVerifier(_gateway).verify(
      repository: request.repository,
      tag: request.tag,
      expectedCommit: request.expectedCommit,
    );
    await _requireNoRelease(request);

    final staged = await _stage(payloads, request.outputDirectory);
    final checksumFile = await _writeChecksums(staged, request.outputDirectory);
    final notesFile = _writeNotes(
      request.outputDirectory,
      tag: request.tag,
      sourceCommit: request.expectedCommit,
      checksums: checksumFile.readAsStringSync(),
    );
    final audience = _audienceFor(request.tag, version);
    final releaseAssets = [...staged.values, checksumFile]
      ..sort(
        (left, right) =>
            p.basename(left.path).compareTo(p.basename(right.path)),
      );

    await _gateway.createDraft(
      CreateDraftRelease(
        repository: request.repository,
        tag: request.tag,
        title: 'Poltergeist ${version.semantic}',
        notesFile: notesFile,
        assets: releaseAssets,
        audience: audience,
        latestSelection: LatestReleaseSelection.excluded,
      ),
    );

    // Re-read both mutable objects after creation to close the race window.
    await ReleaseSourceVerifier(_gateway).verify(
      repository: request.repository,
      tag: request.tag,
      expectedCommit: request.expectedCommit,
    );
    final release = await _verifyCreatedRelease(
      request,
      audience: audience,
      expectedAssets: releaseAssets,
      expectedNotes: notesFile.readAsStringSync(),
    );

    return DraftReleaseReport(
      releaseId: release.id,
      payloadCount: staged.length,
      checksumFile: checksumFile,
      notesFile: notesFile,
    );
  }

  Future<void> _requireNoRelease(PublishDraftRequest request) async {
    final existing = await _gateway.findReleases(
      repository: request.repository,
      tag: request.tag,
    );
    if (existing.isEmpty) return;

    final ids = existing.map((release) => release.id).join(', ');
    throw ReleasePublishException(
      'release for ${request.tag} already exists (id: $ids); refusing to '
      'update or overwrite it',
    );
  }

  Future<ReleaseState> _verifyCreatedRelease(
    PublishDraftRequest request, {
    required ReleaseAudience audience,
    required List<File> expectedAssets,
    required String expectedNotes,
  }) async {
    final releases = await _gateway.findReleases(
      repository: request.repository,
      tag: request.tag,
    );
    if (releases.length != 1) {
      throw ReleasePublishException(
        'expected exactly one release for ${request.tag}; found '
        '${releases.length}',
      );
    }

    final release = releases.single;
    if (release.visibility != ReleaseVisibility.draft) {
      throw ReleasePublishException(
        'release ${release.id} is not a draft; publication halted',
      );
    }
    if (release.audience != audience) {
      throw ReleasePublishException(
        'release ${release.id} has the wrong prerelease state',
      );
    }

    final expectedSizes = {
      for (final file in expectedAssets)
        p.basename(file.path): file.lengthSync(),
    };
    final expectedNames = expectedSizes.keys.toSet();
    final actualNames = release.assets.map((asset) => asset.name).toList();
    final actualSet = actualNames.toSet();
    final hasDuplicates = actualSet.length != actualNames.length;
    final hasWrongSize = release.assets.any(
      (asset) => asset.size <= 0 || expectedSizes[asset.name] != asset.size,
    );
    if (hasDuplicates ||
        hasWrongSize ||
        actualSet.length != expectedNames.length ||
        !actualSet.containsAll(expectedNames)) {
      throw ReleasePublishException(
        'remote release assets do not match the closed asset set; expected '
        '${expectedNames.toList()..sort()}, found ${actualNames..sort()}',
      );
    }
    if (release.notes != expectedNotes) {
      throw ReleasePublishException(
        'remote release notes do not match the generated checksum notes',
      );
    }

    return release;
  }
}

ReleaseVersion _validateSourceArguments({
  required String repository,
  required String tag,
  required String expectedCommit,
}) {
  if (!_repositoryPattern.hasMatch(repository)) {
    throw ReleasePublishException('invalid GitHub repository "$repository"');
  }
  if (!_commitPattern.hasMatch(expectedCommit)) {
    throw ReleasePublishException(
      'invalid expected commit "$expectedCommit"; expected a full SHA-1',
    );
  }
  if (!tag.startsWith('v')) {
    throw ReleasePublishException('invalid release tag "$tag"');
  }

  try {
    return ReleaseVersion.parse(tag.substring(1));
  } on ReleaseVersionFormatException catch (error) {
    throw ReleasePublishException(error.message);
  }
}

Future<Map<String, File>> _validatePayloads(
  Directory directory,
  Set<String> expected,
) async {
  if (!directory.existsSync()) {
    throw ReleasePublishException(
      'artifact directory does not exist: ${directory.path}',
    );
  }

  final found = <String, File>{};
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) {
      throw ReleasePublishException(
        'unexpected release payload link: ${entity.path}',
      );
    }
    if (entity is! File) continue;

    final name = p.basename(entity.path);
    if (!expected.contains(name)) {
      throw ReleasePublishException('unexpected release payload: $name');
    }
    if (found.containsKey(name)) {
      throw ReleasePublishException('duplicate release payload: $name');
    }
    if (await entity.length() <= 0) {
      throw ReleasePublishException('empty release payload: $name');
    }

    found[name] = entity;
  }

  final missing = expected.difference(found.keys.toSet()).toList()..sort();
  if (missing.isNotEmpty) {
    throw ReleasePublishException(
      'missing release payload${missing.length == 1 ? '' : 's'}: '
      '${missing.join(', ')}',
    );
  }
  return found;
}

void _validateOutputPath(PublishDraftRequest request) {
  final outputPath = p.normalize(p.absolute(request.outputDirectory.path));
  final artifactsPath = p.normalize(
    p.absolute(request.artifactsDirectory.path),
  );
  if (p.equals(outputPath, artifactsPath) ||
      p.isWithin(artifactsPath, outputPath)) {
    throw const ReleasePublishException(
      'output path must be outside the artifact directory',
    );
  }
  if (FileSystemEntity.typeSync(outputPath) == FileSystemEntityType.notFound) {
    return;
  }

  throw ReleasePublishException('output path already exists: $outputPath');
}

Future<Map<String, File>> _stage(
  Map<String, File> payloads,
  Directory output,
) async {
  output.createSync();
  final staged = <String, File>{};
  final names = payloads.keys.toList()..sort();
  for (final name in names) {
    final destination = File(p.join(output.path, name));
    await payloads[name]!.copy(destination.path);
    if (await destination.length() <= 0) {
      throw ReleasePublishException('staged release payload is empty: $name');
    }

    staged[name] = destination;
  }

  return staged;
}

Future<File> _writeChecksums(
  Map<String, File> payloads,
  Directory output,
) async {
  late final ReleaseChecksumManifest manifest;
  try {
    manifest = await ReleaseChecksumManifest.create(payloads);
  } on ReleaseArtifactException catch (error) {
    throw ReleasePublishException(error.message);
  }

  final checksumFile = File(p.join(output.path, kReleaseChecksumFileName));
  await checksumFile.writeAsString(manifest.encode(), flush: true);
  return checksumFile;
}

File _writeNotes(
  Directory output, {
  required String tag,
  required String sourceCommit,
  required String checksums,
}) {
  final notes = File(p.join(output.path, _notesFileName));
  final document = ReleaseNotesDocument.create(
    tag: tag,
    sourceCommit: sourceCommit,
    checksums: checksums,
  );
  notes.writeAsStringSync(document.encode(), flush: true);
  return notes;
}

ReleaseAudience _audienceFor(String tag, ReleaseVersion version) {
  if (version.semantic.startsWith('0.')) return ReleaseAudience.prerelease;
  if (tag.contains('-')) return ReleaseAudience.prerelease;

  return ReleaseAudience.stable;
}

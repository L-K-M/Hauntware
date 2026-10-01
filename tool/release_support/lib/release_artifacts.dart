// Release tools share one closed artifact and checksum contract.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../release_version/lib/release_version.dart';

const String kReleaseChecksumFileName = 'SHA256SUMS';
const String kReleaseSignatureFileName = 'SHA256SUMS.asc';
const String kAndroidReleaseDisclosure =
    'The Android APK is a rehearsal artifact of the desktop codebase and is an\n'
    'unsupported v1 target.';
const String kIosReleaseDisclosure =
    'The iOS IPA is unsigned and unsupported; re-sign it before installation.';

final RegExp _checksumLinePattern = RegExp(r'^([0-9a-f]{64})  ([^/\\\r\n]+)$');
final RegExp _sourceCommitPattern = RegExp(r'^[0-9a-f]{40}$');

final class ReleaseArtifactException implements Exception {
  final String message;

  const ReleaseArtifactException(this.message);

  @override
  String toString() => message;
}

/// The one filename set shared by CI publication and local finalization.
final class ReleaseArtifactManifest {
  final Set<String> payloadNames;
  final Set<String> unsignedNames;
  final Set<String> signedNames;

  ReleaseArtifactManifest._(Set<String> payloads)
    : payloadNames = Set.unmodifiable(payloads),
      unsignedNames = Set.unmodifiable({...payloads, kReleaseChecksumFileName}),
      signedNames = Set.unmodifiable({
        ...payloads,
        kReleaseChecksumFileName,
        kReleaseSignatureFileName,
      });

  factory ReleaseArtifactManifest.forTag(String tag) {
    if (!tag.startsWith('v')) {
      throw ReleaseArtifactException('invalid release tag "$tag"');
    }

    late final ReleaseVersion version;
    try {
      version = ReleaseVersion.parse(tag.substring(1));
    } on ReleaseVersionFormatException catch (error) {
      throw ReleaseArtifactException(error.message);
    }

    return ReleaseArtifactManifest._({
      'poltergeist-android.apk',
      'poltergeist-ios-unsigned.ipa',
      'poltergeist-linux-x64.AppImage',
      'poltergeist-linux-x64.tar.gz',
      'poltergeist-macos-universal.zip',
      'poltergeist-windows-x64.zip',
      'poltergeist_${version.debianPackageVersion}_amd64.deb',
    });
  }
}

/// Canonical release notes bind CI payloads to one tagged source commit.
final class ReleaseNotesDocument {
  final String _contents;

  ReleaseNotesDocument._(this._contents);

  factory ReleaseNotesDocument.create({
    required String tag,
    required String sourceCommit,
    required String checksums,
  }) {
    if (!tag.startsWith('v')) {
      throw ReleaseArtifactException('invalid release tag "$tag"');
    }

    late final ReleaseVersion version;
    try {
      version = ReleaseVersion.parse(tag.substring(1));
    } on ReleaseVersionFormatException catch (error) {
      throw ReleaseArtifactException(error.message);
    }
    final normalizedCommit = sourceCommit.toLowerCase();
    if (!_sourceCommitPattern.hasMatch(normalizedCommit)) {
      throw ReleaseArtifactException(
        'invalid release source commit "$sourceCommit"',
      );
    }
    if (!checksums.endsWith('\n') || checksums.endsWith('\n\n')) {
      throw const ReleaseArtifactException(
        'release checksums must end with one newline',
      );
    }

    return ReleaseNotesDocument._('''# Poltergeist ${version.semantic}

Source tag: `$tag`
Source commit: `$normalizedCommit`

$kAndroidReleaseDisclosure

$kIosReleaseDisclosure

## SHA-256 checksums

```text
${checksums.trimRight()}
```
''');
  }

  static void verifyCanonical(
    String contents, {
    required String tag,
    required String sourceCommit,
    required String checksums,
  }) {
    final expected = ReleaseNotesDocument.create(
      tag: tag,
      sourceCommit: sourceCommit,
      checksums: checksums,
    ).encode();
    if (contents == expected) return;

    throw const ReleaseArtifactException(
      'release notes do not match the source commit, checksums, and required '
      'platform disclosures',
    );
  }

  String encode() => _contents;
}

/// A canonical GNU-style SHA-256 list over release payloads only.
final class ReleaseChecksumManifest {
  final Map<String, String> _digests;

  ReleaseChecksumManifest._(Map<String, String> digests)
    : _digests = UnmodifiableMapView(digests);

  static Future<ReleaseChecksumManifest> create(
    Map<String, File> payloads,
  ) async {
    if (payloads.isEmpty) {
      throw const ReleaseArtifactException('release payload set is empty');
    }

    final digests = <String, String>{};
    final names = payloads.keys.toList()..sort();
    for (final name in names) {
      _requireSafeName(name);
      final file = payloads[name]!;
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.file || await file.length() <= 0) {
        throw ReleaseArtifactException(
          'release payload is missing, linked, or empty: $name',
        );
      }

      digests[name] = (await sha256.bind(file.openRead()).first).toString();
    }

    return ReleaseChecksumManifest._(digests);
  }

  factory ReleaseChecksumManifest.parseCanonical(
    String contents, {
    required Set<String> expectedNames,
  }) {
    if (!contents.endsWith('\n') || contents.endsWith('\n\n')) {
      throw const ReleaseArtifactException(
        'checksum manifest must end with one newline',
      );
    }

    final lines = contents.substring(0, contents.length - 1).split('\n');
    final expected = expectedNames.toList()..sort();
    if (lines.length != expected.length) {
      throw ReleaseArtifactException(
        'checksum manifest has ${lines.length} entries; expected '
        '${expected.length}',
      );
    }

    final digests = <String, String>{};
    for (var index = 0; index < lines.length; index++) {
      final match = _checksumLinePattern.firstMatch(lines[index]);
      if (match == null) {
        throw ReleaseArtifactException(
          'checksum manifest line ${index + 1} is not canonical',
        );
      }

      final name = match[2]!;
      _requireSafeName(name);
      if (name != expected[index]) {
        throw ReleaseArtifactException(
          'checksum manifest names are missing, duplicated, or unsorted',
        );
      }
      digests[name] = match[1]!;
    }

    return ReleaseChecksumManifest._(digests);
  }

  String encode() {
    final names = _digests.keys.toList()..sort();
    return '${[for (final name in names) '${_digests[name]}  $name'].join('\n')}\n';
  }

  Future<void> verifyFiles(Directory directory) async {
    for (final entry in _digests.entries) {
      final file = File(p.join(directory.path, entry.key));
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.file || await file.length() <= 0) {
        throw ReleaseArtifactException(
          'release payload is missing, linked, or empty: ${entry.key}',
        );
      }

      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual == entry.value) continue;

      throw ReleaseArtifactException(
        'release payload digest mismatch: ${entry.key}',
      );
    }
  }
}

void _requireSafeName(String name) {
  if (name.isNotEmpty &&
      p.basename(name) == name &&
      name != '.' &&
      name != '..') {
    return;
  }

  throw ReleaseArtifactException('invalid release payload name: "$name"');
}

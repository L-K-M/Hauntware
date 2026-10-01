// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_artifacts.dart';

void main() {
  late Directory sandbox;
  late ReleaseArtifactManifest artifacts;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-artifacts-test-',
    );
    artifacts = ReleaseArtifactManifest.forTag('v0.1.0');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('derives the exact immutable artifact sets from the tag', () {
    expect(artifacts.payloadNames, hasLength(7));
    expect(artifacts.payloadNames, contains('poltergeist_0.1.0-1_amd64.deb'));
    expect(artifacts.unsignedNames, {...artifacts.payloadNames, 'SHA256SUMS'});
    expect(artifacts.signedNames, {
      ...artifacts.unsignedNames,
      'SHA256SUMS.asc',
    });
    expect(
      () => artifacts.payloadNames.add('foreign.zip'),
      throwsUnsupportedError,
    );
  });

  test('uses Debian ordering in prerelease artifact names', () {
    final beta = ReleaseArtifactManifest.forTag('v0.2.0-beta1');
    final candidate = ReleaseArtifactManifest.forTag('v0.2.0-rc2');

    expect(beta.payloadNames, contains('poltergeist_0.2.0~beta1-1_amd64.deb'));
    expect(
      candidate.payloadNames,
      contains('poltergeist_0.2.0~rc2-1_amd64.deb'),
    );
  });

  test('creates and parses one canonical sorted checksum manifest', () async {
    final files = <String, File>{};
    for (final name in artifacts.payloadNames.toList().reversed) {
      files[name] = File(p.join(sandbox.path, name))..writeAsStringSync(name);
    }

    final manifest = await ReleaseChecksumManifest.create(files);
    final encoded = manifest.encode();
    final parsed = ReleaseChecksumManifest.parseCanonical(
      encoded,
      expectedNames: artifacts.payloadNames,
    );

    expect(parsed.encode(), encoded);
    expect(encoded, endsWith('\n'));
    expect(
      encoded
          .split('\n')
          .where((line) => line.isNotEmpty)
          .map((line) => line.substring(66)),
      orderedEquals(artifacts.payloadNames.toList()..sort()),
    );
    await parsed.verifyFiles(sandbox);
  });

  test('canonical notes bind source, checksums, and platform disclosures', () {
    const sourceCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final checksums = '${List.filled(64, '0').join()}  artifact.zip\n';
    final notes = ReleaseNotesDocument.create(
      tag: 'v0.1.0',
      sourceCommit: sourceCommit,
      checksums: checksums,
    ).encode();

    expect(notes, contains('Source commit: `$sourceCommit`'));
    expect(notes, contains(kAndroidReleaseDisclosure));
    expect(notes, contains(kIosReleaseDisclosure));
    expect(
      () => ReleaseNotesDocument.verifyCanonical(
        notes.replaceFirst(kIosReleaseDisclosure, 'supported'),
        tag: 'v0.1.0',
        sourceCommit: sourceCommit,
        checksums: checksums,
      ),
      throwsA(isA<ReleaseArtifactException>()),
    );
  });

  test('rejects malformed, reordered, missing, duplicate, or path entries', () {
    final names = artifacts.payloadNames.toList()..sort();
    final digest = sha256.convert(const [1]).toString();
    final valid = [for (final name in names) '$digest  $name'].join('\n');
    final cases = <String>[
      valid,
      '${valid.replaceFirst(digest, digest.toUpperCase())}\n',
      '${valid.replaceFirst('  ', ' ')}\n',
      '${[for (final name in names.reversed) '$digest  $name'].join('\n')}\n',
      '${[for (final name in names.skip(1)) '$digest  $name'].join('\n')}\n',
      '${List.filled(names.length, '$digest  ${names.first}').join('\n')}\n',
      '${valid.replaceFirst(names.first, '../${names.first}')}\n',
    ];

    for (final contents in cases) {
      expect(
        () => ReleaseChecksumManifest.parseCanonical(
          contents,
          expectedNames: artifacts.payloadNames,
        ),
        throwsA(isA<ReleaseArtifactException>()),
      );
    }
  });

  test('detects an asset changed after checksum creation', () async {
    final files = <String, File>{};
    for (final name in artifacts.payloadNames) {
      files[name] = File(p.join(sandbox.path, name))..writeAsStringSync(name);
    }
    final manifest = await ReleaseChecksumManifest.create(files);
    files.values.first.writeAsStringSync('changed');

    await expectLater(
      manifest.verifyFiles(sandbox),
      throwsA(isA<ReleaseArtifactException>()),
    );
  });
}

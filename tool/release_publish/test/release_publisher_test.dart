// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../release_support/lib/release_artifacts.dart';
import '../lib/release_publisher.dart';

const String _repository = 'L-K-M/Poltergeist';
const String _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _secondCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String _finalTag = 'v1.0.0';
const String _rehearsalTag = 'v0.1.0';
const String _candidateTag = 'v1.1.0-rc2';

void main() {
  late Directory sandbox;
  late Directory artifacts;
  late Directory output;
  late _FakeGitHub gateway;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-publish-test-',
    );
    artifacts = Directory(p.join(sandbox.path, 'artifacts'))..createSync();
    output = Directory(p.join(sandbox.path, 'output'));
    gateway = _FakeGitHub(
      tag: const ReleaseTagState(
        name: _rehearsalTag,
        commit: _commit,
        signature: ReleaseSignature.verifiedOpenPgp,
      ),
    );
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'publishes one closed rehearsal draft with deterministic sums',
    () async {
      final payloads = _writePayloads(artifacts, _rehearsalTag);

      final report = await DraftReleasePublisher(gateway).publish(
        PublishDraftRequest(
          repository: _repository,
          tag: _rehearsalTag,
          expectedCommit: _commit,
          artifactsDirectory: artifacts,
          outputDirectory: output,
        ),
      );

      final request = gateway.created.single;
      expect(request.audience, ReleaseAudience.prerelease);
      expect(request.latestSelection, LatestReleaseSelection.excluded);
      expect(
        request.assets.map((file) => p.basename(file.path)),
        unorderedEquals({...payloads.keys, 'SHA256SUMS'}),
      );

      final names = payloads.keys.toList()..sort();
      final expectedLines = [
        for (final name in names) '${sha256.convert(payloads[name]!)}  $name',
      ];
      final sums = report.checksumFile.readAsStringSync();
      expect(sums, '${expectedLines.join('\n')}\n');

      final notes = report.notesFile.readAsStringSync();
      expect(notes, contains(_commit));
      expect(notes, contains(sums.trimRight()));
      expect(notes, contains('Android APK is a rehearsal artifact'));
      expect(notes, contains('unsupported'));
      expect(notes, contains('iOS IPA is unsigned'));
      expect(notes, contains('re-sign'));
      expect(report.payloadCount, 7);
    },
  );

  test('publishes a final tag as a non-latest stable draft', () async {
    _writePayloads(artifacts, _finalTag);
    gateway.tag = const ReleaseTagState(
      name: _finalTag,
      commit: _commit,
      signature: ReleaseSignature.verifiedOpenPgp,
    );

    await DraftReleasePublisher(gateway).publish(
      PublishDraftRequest(
        repository: _repository,
        tag: _finalTag,
        expectedCommit: _commit,
        artifactsDirectory: artifacts,
        outputDirectory: output,
      ),
    );

    expect(gateway.created.single.audience, ReleaseAudience.stable);
    expect(
      gateway.created.single.latestSelection,
      LatestReleaseSelection.excluded,
    );
  });

  test('publishes a hyphenated tag as a prerelease', () async {
    _writePayloads(artifacts, _candidateTag);
    gateway.tag = const ReleaseTagState(
      name: _candidateTag,
      commit: _commit,
      signature: ReleaseSignature.verifiedOpenPgp,
    );

    await DraftReleasePublisher(gateway).publish(
      PublishDraftRequest(
        repository: _repository,
        tag: _candidateTag,
        expectedCommit: _commit,
        artifactsDirectory: artifacts,
        outputDirectory: output,
      ),
    );

    final names = gateway.created.single.assets.map(
      (file) => p.basename(file.path),
    );
    expect(names, contains('poltergeist_1.1.0~rc2-1_amd64.deb'));
    expect(gateway.created.single.audience, ReleaseAudience.prerelease);
  });

  test('rejects a missing payload before querying GitHub', () async {
    final payloads = _writePayloads(artifacts, _rehearsalTag);
    _payloadFile(artifacts, payloads.keys.first).deleteSync();

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('missing release payload')),
    );
    expect(gateway.readTagCalls, 0);
  });

  test('rejects an empty payload before querying GitHub', () async {
    final payloads = _writePayloads(artifacts, _rehearsalTag);
    _payloadFile(artifacts, payloads.keys.first).writeAsBytesSync([]);

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('empty release payload')),
    );
    expect(gateway.readTagCalls, 0);
  });

  test('rejects an unexpected payload before querying GitHub', () async {
    _writePayloads(artifacts, _rehearsalTag);
    File(p.join(artifacts.path, 'foreign.zip')).writeAsStringSync('foreign');

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('unexpected release payload')),
    );
    expect(gateway.readTagCalls, 0);
  });

  test('rejects duplicate payload names before querying GitHub', () async {
    final payloads = _writePayloads(artifacts, _rehearsalTag);
    final duplicate = File(
      p.join(artifacts.path, 'duplicate', payloads.keys.first),
    )..createSync(recursive: true);
    duplicate.writeAsStringSync('duplicate');

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('duplicate release payload')),
    );
    expect(gateway.readTagCalls, 0);
  });

  test('rejects an existing output directory to prevent overwrite', () async {
    _writePayloads(artifacts, _rehearsalTag);
    output.createSync();

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('output path already exists')),
    );
    expect(gateway.readTagCalls, 0);
  });

  test('rejects a remote tag at another commit', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.tag = const ReleaseTagState(
      name: _rehearsalTag,
      commit: _secondCommit,
      signature: ReleaseSignature.verifiedOpenPgp,
    );

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('does not match expected commit')),
    );
    expect(gateway.created, isEmpty);
  });

  test('rejects a tag without a verified OpenPGP signature', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.tag = const ReleaseTagState(
      name: _rehearsalTag,
      commit: _commit,
      signature: ReleaseSignature.invalid,
    );

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('verified OpenPGP signature')),
    );
    expect(gateway.created, isEmpty);
  });

  test('rejects any existing draft or published release', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.releases = [
      const ReleaseState(
        id: 17,
        tag: _rehearsalTag,
        visibility: ReleaseVisibility.draft,
        audience: ReleaseAudience.prerelease,
        assets: [],
        notes: '',
      ),
    ];

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('already exists')),
    );
    expect(gateway.created, isEmpty);
  });

  test('rejects a changed tag after draft creation', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.tagAfterCreate = const ReleaseTagState(
      name: _rehearsalTag,
      commit: _secondCommit,
      signature: ReleaseSignature.verifiedOpenPgp,
    );

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('does not match expected commit')),
    );
    expect(gateway.created, hasLength(1));
  });

  test('rejects an incomplete remote draft after creation', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.releaseAfterCreate = const ReleaseState(
      id: 18,
      tag: _rehearsalTag,
      visibility: ReleaseVisibility.draft,
      audience: ReleaseAudience.prerelease,
      assets: [ReleaseAssetState(name: 'SHA256SUMS', size: 1)],
      notes: '',
    );

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('remote release assets do not match')),
    );
    expect(gateway.created, hasLength(1));
  });

  test('rejects a release that was not left drafted', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.visibilityAfterCreate = ReleaseVisibility.published;

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('is not a draft')),
    );
  });

  test('rejects changed remote release notes', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.notesAfterCreate = 'altered';

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('release notes do not match')),
    );
  });

  test('rejects a remote asset with another size', () async {
    _writePayloads(artifacts, _rehearsalTag);
    gateway.assetSizeAdjustment = 1;

    await expectLater(
      _publish(gateway, artifacts, output),
      throwsA(_errorContaining('remote release assets do not match')),
    );
  });
}

Future<DraftReleaseReport> _publish(
  GitHubReleaseGateway gateway,
  Directory artifacts,
  Directory output,
) {
  return DraftReleasePublisher(gateway).publish(
    PublishDraftRequest(
      repository: _repository,
      tag: _rehearsalTag,
      expectedCommit: _commit,
      artifactsDirectory: artifacts,
      outputDirectory: output,
    ),
  );
}

Matcher _errorContaining(String text) {
  return isA<ReleasePublishException>().having(
    (error) => error.message,
    'message',
    contains(text),
  );
}

Map<String, List<int>> _writePayloads(Directory root, String tag) {
  final names = ReleaseArtifactManifest.forTag(tag).payloadNames.toList()
    ..sort();
  final contents = <String, List<int>>{
    for (var index = 0; index < names.length; index++)
      names[index]: [index + 1],
  };

  var index = 0;
  for (final entry in contents.entries) {
    final platform = Directory(p.join(root.path, 'artifact-${index++}'))
      ..createSync();
    File(p.join(platform.path, entry.key)).writeAsBytesSync(entry.value);
  }

  return contents;
}

File _payloadFile(Directory root, String name) {
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .singleWhere((file) => p.basename(file.path) == name);
}

final class _FakeGitHub implements GitHubReleaseGateway {
  ReleaseTagState tag;
  ReleaseTagState? tagAfterCreate;
  List<ReleaseState> releases = [];
  ReleaseState? releaseAfterCreate;
  ReleaseVisibility visibilityAfterCreate = ReleaseVisibility.draft;
  String? notesAfterCreate;
  int assetSizeAdjustment = 0;
  final List<CreateDraftRelease> created = [];
  int readTagCalls = 0;

  _FakeGitHub({required this.tag});

  @override
  Future<void> createDraft(CreateDraftRelease request) async {
    created.add(request);
    tag = tagAfterCreate ?? tag;
    if (releaseAfterCreate != null) {
      releases = [releaseAfterCreate!];
      return;
    }

    releases = [
      ReleaseState(
        id: 18,
        tag: request.tag,
        visibility: visibilityAfterCreate,
        audience: request.audience,
        assets: [
          for (final file in request.assets)
            ReleaseAssetState(
              name: p.basename(file.path),
              size: file.lengthSync() + assetSizeAdjustment,
            ),
        ],
        notes: notesAfterCreate ?? request.notesFile.readAsStringSync(),
      ),
    ];
  }

  @override
  Future<List<ReleaseState>> findReleases({
    required String repository,
    required String tag,
  }) async {
    return releases.where((release) => release.tag == tag).toList();
  }

  @override
  Future<ReleaseTagState> readTag({
    required String repository,
    required String tag,
  }) async {
    readTagCalls++;
    return this.tag;
  }
}

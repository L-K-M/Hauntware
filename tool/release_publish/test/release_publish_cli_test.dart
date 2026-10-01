// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_publish_cli.dart';
import '../lib/release_publisher.dart';

const String _repository = 'L-K-M/Poltergeist';
const String _tag = 'v0.1.0';
const String _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory sandbox;
  late _FakeGateway gateway;
  late List<String> output;
  late List<String> errors;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-publish-cli-test-',
    );
    gateway = _FakeGateway();
    output = [];
    errors = [];
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('verify-source checks the remote signed tag', () async {
    final code = await runReleasePublishCommand(
      [
        'verify-source',
        '--repository',
        _repository,
        '--tag',
        _tag,
        '--commit',
        _commit,
      ],
      gateway: gateway,
      workingDirectory: sandbox,
      writeOutput: output.add,
      writeError: errors.add,
    );

    expect(code, 0);
    expect(gateway.readTagCalls, 1);
    expect(gateway.created, isEmpty);
    expect(output.single, contains('verified'));
    expect(errors, isEmpty);
  });

  test('publish resolves paths and creates the draft', () async {
    final artifacts = Directory(p.join(sandbox.path, 'artifacts'))
      ..createSync();
    _writePayloads(artifacts);

    final code = await runReleasePublishCommand(
      [
        'publish',
        '--repository',
        _repository,
        '--tag',
        _tag,
        '--commit',
        _commit,
        '--artifacts',
        'artifacts',
        '--output',
        'publish-output',
      ],
      gateway: gateway,
      workingDirectory: sandbox,
      writeOutput: output.add,
      writeError: errors.add,
    );

    expect(code, 0);
    expect(gateway.created, hasLength(1));
    expect(
      Directory(p.join(sandbox.path, 'publish-output')).existsSync(),
      isTrue,
    );
    expect(output.single, contains('7 payloads'));
    expect(errors, isEmpty);
  });

  test('invalid arguments return usage without touching GitHub', () async {
    final code = await runReleasePublishCommand(
      ['publish', '--tag', _tag],
      gateway: gateway,
      workingDirectory: sandbox,
      writeOutput: output.add,
      writeError: errors.add,
    );

    expect(code, 64);
    expect(gateway.readTagCalls, 0);
    expect(errors.single, startsWith('usage:'));
  });
}

void _writePayloads(Directory root) {
  const names = [
    'poltergeist-android.apk',
    'poltergeist-ios-unsigned.ipa',
    'poltergeist-linux-x64.AppImage',
    'poltergeist-linux-x64.tar.gz',
    'poltergeist-macos-universal.zip',
    'poltergeist-windows-x64.zip',
    'poltergeist_0.1.0-1_amd64.deb',
  ];
  for (final name in names) {
    File(p.join(root.path, name)).writeAsStringSync(name);
  }
}

final class _FakeGateway implements GitHubReleaseGateway {
  final List<CreateDraftRelease> created = [];
  List<ReleaseState> releases = [];
  int readTagCalls = 0;

  @override
  Future<void> createDraft(CreateDraftRelease request) async {
    created.add(request);
    releases = [
      ReleaseState(
        id: 1,
        tag: request.tag,
        visibility: ReleaseVisibility.draft,
        audience: request.audience,
        assets: [
          for (final file in request.assets)
            ReleaseAssetState(
              name: p.basename(file.path),
              size: file.lengthSync(),
            ),
        ],
        notes: request.notesFile.readAsStringSync(),
      ),
    ];
  }

  @override
  Future<List<ReleaseState>> findReleases({
    required String repository,
    required String tag,
  }) async {
    return releases;
  }

  @override
  Future<ReleaseTagState> readTag({
    required String repository,
    required String tag,
  }) async {
    readTagCalls++;
    return const ReleaseTagState(
      name: _tag,
      commit: _commit,
      signature: ReleaseSignature.verifiedOpenPgp,
    );
  }
}

// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../lib/gh_release_gateway.dart';
import '../lib/release_publisher.dart';

const String _repository = 'L-K-M/Poltergeist';
const String _tag = 'v0.1.0';
const String _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _tagObject = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  test('reads a GitHub-verified OpenPGP annotated tag', () async {
    final runner = _FakeRunner([
      _jsonResult({
        'object': {'type': 'tag', 'sha': _tagObject},
      }),
      _jsonResult({
        'tag': _tag,
        'object': {'type': 'commit', 'sha': _commit},
        'verification': {
          'verified': true,
          'reason': 'valid',
          'signature': '-----BEGIN PGP SIGNATURE-----\nsigned\n',
        },
      }),
    ]);

    final state = await GhReleaseGateway.withRunner(
      runner,
    ).readTag(repository: _repository, tag: _tag);

    expect(state.name, _tag);
    expect(state.commit, _commit);
    expect(state.signature, ReleaseSignature.verifiedOpenPgp);
    expect(runner.calls, hasLength(2));
    expect(
      runner.calls.first.arguments,
      contains('repos/$_repository/git/ref/tags/$_tag'),
    );
    expect(
      runner.calls.last.arguments,
      contains('repos/$_repository/git/tags/$_tagObject'),
    );
  });

  test('marks a lightweight tag invalid', () async {
    final runner = _FakeRunner([
      _jsonResult({
        'object': {'type': 'commit', 'sha': _commit},
      }),
    ]);

    final state = await GhReleaseGateway.withRunner(
      runner,
    ).readTag(repository: _repository, tag: _tag);

    expect(state.commit, _commit);
    expect(state.signature, ReleaseSignature.invalid);
    expect(runner.calls, hasLength(1));
  });

  test(
    'lists draft and published releases without treating errors as empty',
    () async {
      final runner = _FakeRunner([
        _jsonResult([
          [
            {
              'id': 4,
              'tag_name': _tag,
              'draft': true,
              'prerelease': true,
              'body': 'release notes',
              'assets': [
                {'name': 'one.zip', 'size': 12},
              ],
            },
            {
              'id': 5,
              'tag_name': 'v9.9.9',
              'draft': false,
              'prerelease': false,
              'body': '',
              'assets': const [],
            },
          ],
        ]),
      ]);

      final releases = await GhReleaseGateway.withRunner(
        runner,
      ).findReleases(repository: _repository, tag: _tag);

      expect(releases, hasLength(1));
      expect(releases.single.visibility, ReleaseVisibility.draft);
      expect(releases.single.audience, ReleaseAudience.prerelease);
      expect(releases.single.assets.single.name, 'one.zip');
      expect(releases.single.notes, 'release notes');
    },
  );

  test('creates a draft with verify-tag and no latest promotion', () async {
    final runner = _FakeRunner([const ReleaseCommandResult(exitCode: 0)]);
    final sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-gh-release-test-',
    );
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final notes = File('${sandbox.path}/notes.md')..writeAsStringSync('notes');
    final asset = File('${sandbox.path}/asset.zip')..writeAsStringSync('asset');

    await GhReleaseGateway.withRunner(runner).createDraft(
      CreateDraftRelease(
        repository: _repository,
        tag: _tag,
        title: 'Poltergeist 0.1.0',
        notesFile: notes,
        assets: [asset],
        audience: ReleaseAudience.prerelease,
        latestSelection: LatestReleaseSelection.excluded,
      ),
    );

    final call = runner.calls.single;
    expect(call.executable, 'gh');
    expect(
      call.arguments,
      containsAll(<String>[
        'release',
        'create',
        _tag,
        '--verify-tag',
        '--draft',
        '--prerelease',
        '--latest=false',
      ]),
    );
    expect(call.arguments, isNot(contains('--target')));
    expect(call.arguments.last, asset.path);
  });

  test('fails closed when gh cannot list releases', () async {
    final runner = _FakeRunner([
      const ReleaseCommandResult(exitCode: 1, standardError: 'network down'),
    ]);

    await expectLater(
      GhReleaseGateway.withRunner(
        runner,
      ).findReleases(repository: _repository, tag: _tag),
      throwsA(
        isA<ReleasePublishException>().having(
          (error) => error.message,
          'message',
          contains('network down'),
        ),
      ),
    );
  });
}

ReleaseCommandResult _jsonResult(Object value) {
  return ReleaseCommandResult(exitCode: 0, standardOutput: jsonEncode(value));
}

final class _FakeRunner implements ReleaseCommandRunner {
  final List<ReleaseCommandResult> _results;
  final List<_CommandCall> calls = [];

  _FakeRunner(List<ReleaseCommandResult> results) : _results = [...results];

  @override
  Future<ReleaseCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    calls.add(_CommandCall(executable, [...arguments]));
    if (_results.isEmpty) throw StateError('unexpected command');

    return _results.removeAt(0);
  }
}

final class _CommandCall {
  final String executable;
  final List<String> arguments;

  const _CommandCall(this.executable, this.arguments);
}

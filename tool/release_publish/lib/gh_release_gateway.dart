import 'dart:convert';
import 'dart:io';

import 'release_publisher.dart';

const String _defaultExecutable = 'gh';
const String _openPgpArmor = '-----BEGIN PGP SIGNATURE-----';

final class ReleaseCommandResult {
  final int exitCode;
  final String standardOutput;
  final String standardError;

  const ReleaseCommandResult({
    required this.exitCode,
    this.standardOutput = '',
    this.standardError = '',
  });
}

abstract interface class ReleaseCommandRunner {
  Future<ReleaseCommandResult> run(String executable, List<String> arguments);
}

final class IoReleaseCommandRunner implements ReleaseCommandRunner {
  const IoReleaseCommandRunner();

  @override
  Future<ReleaseCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    return ReleaseCommandResult(
      exitCode: result.exitCode,
      standardOutput: result.stdout.toString(),
      standardError: result.stderr.toString(),
    );
  }
}

/// Encapsulates GitHub's JSON and command-line mechanics behind release terms.
final class GhReleaseGateway implements GitHubReleaseGateway {
  final ReleaseCommandRunner _runner;
  final String _executable;

  const GhReleaseGateway()
    : _runner = const IoReleaseCommandRunner(),
      _executable = _defaultExecutable;

  const GhReleaseGateway.withRunner(
    this._runner, [
    this._executable = _defaultExecutable,
  ]);

  @override
  Future<ReleaseTagState> readTag({
    required String repository,
    required String tag,
  }) async {
    final reference = _asMap(
      await _runJson([
        'api',
        'repos/$repository/git/ref/tags/${Uri.encodeComponent(tag)}',
      ]),
      'tag reference',
    );
    final target = _asMap(reference['object'], 'tag reference target');
    final targetType = _asString(target['type'], 'tag reference target type');
    final targetSha = _asString(target['sha'], 'tag reference target SHA');
    if (targetType == 'commit') {
      return ReleaseTagState(
        name: tag,
        commit: targetSha,
        signature: ReleaseSignature.invalid,
      );
    }
    if (targetType != 'tag') {
      throw ReleasePublishException(
        'remote tag $tag has unsupported target type "$targetType"',
      );
    }

    final annotated = _asMap(
      await _runJson(['api', 'repos/$repository/git/tags/$targetSha']),
      'annotated tag',
    );
    final annotatedName = _asString(annotated['tag'], 'annotated tag name');
    final object = _asMap(annotated['object'], 'annotated tag target');
    final objectType = _asString(object['type'], 'annotated tag target type');
    if (objectType != 'commit') {
      throw ReleasePublishException(
        'remote tag $tag does not point directly to a commit',
      );
    }

    final verification = _asMap(
      annotated['verification'],
      'annotated tag verification',
    );
    final verified = _asBool(
      verification['verified'],
      'annotated tag verification result',
    );
    final signature = verification['signature'];
    final hasOpenPgpSignature =
        signature is String && signature.contains(_openPgpArmor);

    return ReleaseTagState(
      name: annotatedName,
      commit: _asString(object['sha'], 'annotated tag commit'),
      signature: verified && hasOpenPgpSignature
          ? ReleaseSignature.verifiedOpenPgp
          : ReleaseSignature.invalid,
    );
  }

  @override
  Future<List<ReleaseState>> findReleases({
    required String repository,
    required String tag,
  }) async {
    final pages = _asList(
      await _runJson([
        'api',
        '--paginate',
        '--slurp',
        '--method',
        'GET',
        '-f',
        'per_page=100',
        'repos/$repository/releases',
      ]),
      'release pages',
    );
    final matches = <ReleaseState>[];
    for (final pageValue in pages) {
      final page = _asList(pageValue, 'release page');
      for (final releaseValue in page) {
        final release = _asMap(releaseValue, 'release');
        final releaseTag = _asString(release['tag_name'], 'release tag');
        if (releaseTag != tag) continue;

        final assets = <ReleaseAssetState>[];
        for (final assetValue in _asList(release['assets'], 'release assets')) {
          final asset = _asMap(assetValue, 'release asset');
          assets.add(
            ReleaseAssetState(
              name: _asString(asset['name'], 'release asset name'),
              size: _asInt(asset['size'], 'release asset size'),
            ),
          );
        }

        matches.add(
          ReleaseState(
            id: _asInt(release['id'], 'release id'),
            tag: releaseTag,
            visibility: _asBool(release['draft'], 'release draft state')
                ? ReleaseVisibility.draft
                : ReleaseVisibility.published,
            audience: _asBool(release['prerelease'], 'release prerelease state')
                ? ReleaseAudience.prerelease
                : ReleaseAudience.stable,
            assets: assets,
            notes: _asStringAllowEmpty(release['body'], 'release notes'),
          ),
        );
      }
    }

    return matches;
  }

  @override
  Future<void> createDraft(CreateDraftRelease request) async {
    final arguments = <String>[
      'release',
      'create',
      request.tag,
      '--repo',
      request.repository,
      '--verify-tag',
      '--draft',
      switch (request.latestSelection) {
        LatestReleaseSelection.excluded => '--latest=false',
      },
      '--title',
      request.title,
      '--notes-file',
      request.notesFile.path,
      if (request.audience == ReleaseAudience.prerelease) '--prerelease',
      ...request.assets.map((asset) => asset.path),
    ];
    final result = await _runner.run(_executable, arguments);
    if (result.exitCode == 0) return;

    throw ReleasePublishException(
      'GitHub draft creation failed (${result.exitCode}): '
      '${_commandFailure(result)}',
    );
  }

  Future<Object?> _runJson(List<String> arguments) async {
    final result = await _runner.run(_executable, arguments);
    if (result.exitCode != 0) {
      throw ReleasePublishException(
        'GitHub query failed (${result.exitCode}): ${_commandFailure(result)}',
      );
    }

    try {
      return jsonDecode(result.standardOutput);
    } on FormatException catch (error) {
      throw ReleasePublishException('GitHub returned invalid JSON: $error');
    }
  }
}

String _commandFailure(ReleaseCommandResult result) {
  final error = result.standardError.trim();
  if (error.isNotEmpty) return error;

  final output = result.standardOutput.trim();
  return output.isEmpty ? 'no diagnostic output' : output;
}

Map<String, Object?> _asMap(Object? value, String label) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();

  throw ReleasePublishException('GitHub $label is not a JSON object');
}

List<Object?> _asList(Object? value, String label) {
  if (value is List<Object?>) return value;
  if (value is List) return value.cast<Object?>();

  throw ReleasePublishException('GitHub $label is not a JSON list');
}

String _asString(Object? value, String label) {
  if (value is String && value.isNotEmpty) return value;

  throw ReleasePublishException('GitHub $label is missing or invalid');
}

String _asStringAllowEmpty(Object? value, String label) {
  if (value is String) return value;

  throw ReleasePublishException('GitHub $label is missing or invalid');
}

int _asInt(Object? value, String label) {
  if (value is int) return value;

  throw ReleasePublishException('GitHub $label is missing or invalid');
}

bool _asBool(Object? value, String label) {
  if (value is bool) return value;

  throw ReleasePublishException('GitHub $label is missing or invalid');
}

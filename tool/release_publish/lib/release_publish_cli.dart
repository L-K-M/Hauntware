import 'dart:io';

import 'package:path/path.dart' as p;

import 'gh_release_gateway.dart';
import 'release_publisher.dart';

const int _successExitCode = 0;
const int _failureExitCode = 1;
const int _usageExitCode = 64;
const String _usage =
    'usage: release_publish <verify-source|publish> '
    '--repository OWNER/REPO --tag TAG --commit SHA '
    '[--artifacts PATH --output PATH]';

typedef ReleasePublishLineWriter = void Function(String line);

Future<int> runReleasePublishCommand(
  List<String> arguments, {
  GitHubReleaseGateway? gateway,
  Directory? workingDirectory,
  ReleasePublishLineWriter? writeOutput,
  ReleasePublishLineWriter? writeError,
}) async {
  final output = writeOutput ?? stdout.writeln;
  final error = writeError ?? stderr.writeln;
  final parsed = _CommandArguments.parse(arguments);
  if (parsed == null) {
    error(_usage);
    return _usageExitCode;
  }

  final github = gateway ?? const GhReleaseGateway();
  try {
    switch (parsed.command) {
      case _ReleasePublishCommand.verifySource:
        await ReleaseSourceVerifier(github).verify(
          repository: parsed.repository,
          tag: parsed.tag,
          expectedCommit: parsed.commit,
        );
        output(
          '${parsed.tag} verified at ${parsed.commit} with a signed source',
        );
      case _ReleasePublishCommand.publish:
        final base = workingDirectory ?? Directory.current;
        final report = await DraftReleasePublisher(github).publish(
          PublishDraftRequest(
            repository: parsed.repository,
            tag: parsed.tag,
            expectedCommit: parsed.commit,
            artifactsDirectory: _resolveDirectory(base, parsed.artifacts!),
            outputDirectory: _resolveDirectory(base, parsed.output!),
          ),
        );
        output(
          'Created draft release ${report.releaseId} for ${parsed.tag}: '
          '${report.payloadCount} payloads plus SHA256SUMS',
        );
    }

    return _successExitCode;
  } on ReleasePublishException catch (exception) {
    error('release publication failed: ${exception.message}');
    return _failureExitCode;
  } on FileSystemException catch (exception) {
    error('release publication failed: ${exception.message}');
    return _failureExitCode;
  } on ProcessException catch (exception) {
    error('release publication failed: ${exception.message}');
    return _failureExitCode;
  }
}

Directory _resolveDirectory(Directory base, String path) {
  if (p.isAbsolute(path)) return Directory(p.normalize(path));

  return Directory(p.normalize(p.join(base.path, path)));
}

enum _ReleasePublishCommand { verifySource, publish }

final class _CommandArguments {
  final _ReleasePublishCommand command;
  final String repository;
  final String tag;
  final String commit;
  final String? artifacts;
  final String? output;

  const _CommandArguments({
    required this.command,
    required this.repository,
    required this.tag,
    required this.commit,
    required this.artifacts,
    required this.output,
  });

  static _CommandArguments? parse(List<String> arguments) {
    if (arguments.isEmpty) return null;

    final command = switch (arguments.first) {
      'verify-source' => _ReleasePublishCommand.verifySource,
      'publish' => _ReleasePublishCommand.publish,
      _ => null,
    };
    if (command == null) return null;

    final values = <String, String>{};
    for (var index = 1; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length) return null;

      final option = arguments[index];
      if (!const {
        '--repository',
        '--tag',
        '--commit',
        '--artifacts',
        '--output',
      }.contains(option)) {
        return null;
      }
      if (values.containsKey(option)) return null;

      final value = arguments[index + 1];
      if (value.isEmpty) return null;

      values[option] = value;
    }

    final repository = values['--repository'];
    final tag = values['--tag'];
    final commit = values['--commit'];
    if (repository == null || tag == null || commit == null) return null;

    final parsed = _CommandArguments(
      command: command,
      repository: repository,
      tag: tag,
      commit: commit,
      artifacts: values['--artifacts'],
      output: values['--output'],
    );
    return parsed._hasValidShape ? parsed : null;
  }

  bool get _hasValidShape {
    return switch (command) {
      _ReleasePublishCommand.verifySource =>
        artifacts == null && output == null,
      _ReleasePublishCommand.publish => artifacts != null && output != null,
    };
  }
}

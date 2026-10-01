// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../release_version/lib/release_version.dart';
import 'release_finalize_adapters.dart';
import 'release_finalizer.dart';

const int _successExitCode = 0;
const int _failureExitCode = 1;
const int _usageExitCode = 64;
const String _usage =
    'usage: release_finalize --repository OWNER/REPO --tag TAG '
    '--fingerprint 40_HEX [--repo-root PATH]';

typedef ReleaseFinalizeLineWriter = void Function(String line);
typedef ReleaseFinalizeAction =
    Future<ReleaseFinalizationResult> Function(
      ReleaseFinalizeInvocation invocation,
    );

final class ReleaseFinalizeInvocation {
  final String repository;
  final String tag;
  final String expectedFingerprint;
  final Directory repositoryRoot;
  final Directory workingDirectory;

  const ReleaseFinalizeInvocation({
    required this.repository,
    required this.tag,
    required this.expectedFingerprint,
    required this.repositoryRoot,
    required this.workingDirectory,
  });
}

Future<int> runReleaseFinalizeCommand(
  List<String> arguments, {
  ReleaseFinalizeAction? action,
  ReleaseFinalizeLineWriter? writeOutput,
  ReleaseFinalizeLineWriter? writeError,
  Directory? currentDirectory,
}) async {
  final output = writeOutput ?? stdout.writeln;
  final error = writeError ?? stderr.writeln;
  final parsed = _CommandArguments.parse(arguments);
  if (parsed == null) {
    error(_usage);
    return _usageExitCode;
  }

  String fingerprint;
  try {
    fingerprint = validateOpenPgpFingerprint(parsed.fingerprint);
    ReleaseVersion.parse(parsed.tag.substring(1));
  } on FormatException catch (exception) {
    error('${exception.message}\n$_usage');
    return _usageExitCode;
  } on ReleaseVersionFormatException catch (exception) {
    error('${exception.message}\n$_usage');
    return _usageExitCode;
  }

  final base = (currentDirectory ?? Directory.current).absolute;
  final repositoryRoot = _resolveDirectory(base, parsed.repositoryRoot);
  final work = Directory.systemTemp.createTempSync(
    'poltergeist-release-finalize-',
  );
  final invocation = ReleaseFinalizeInvocation(
    repository: parsed.repository,
    tag: parsed.tag,
    expectedFingerprint: fingerprint,
    repositoryRoot: repositoryRoot,
    workingDirectory: work,
  );

  try {
    final result = await (action ?? _finalize)(invocation);
    if (result.status == ReleaseFinalizationStatus.published) {
      output('${invocation.tag} published and reverified');
      return _successExitCode;
    }

    final detail = result.detail.isEmpty ? result.status.name : result.detail;
    error('release finalization halted: $detail');
    return _failureExitCode;
  } on ReleaseFinalizeException catch (exception) {
    error('release finalization failed: ${exception.message}');
    return _failureExitCode;
  } on FileSystemException catch (exception) {
    error('release finalization failed: ${exception.message}');
    return _failureExitCode;
  } on ProcessException catch (exception) {
    error('release finalization failed: ${exception.message}');
    return _failureExitCode;
  } on UnsupportedError catch (exception) {
    error('release finalization failed: ${exception.message}');
    return _failureExitCode;
  } finally {
    if (work.existsSync()) work.deleteSync(recursive: true);
  }
}

Future<ReleaseFinalizationResult> _finalize(
  ReleaseFinalizeInvocation invocation,
) async {
  final signatures = GitGpgReleaseSignatureService(
    repository: invocation.repository,
    repositoryRoot: invocation.repositoryRoot,
  );
  final repository = GhReleaseRepository(
    repository: invocation.repository,
    signatures: signatures,
    expectedFingerprint: invocation.expectedFingerprint,
  );
  final driver = DesktopPrimaryPlatformReleaseDriver.current();
  final auditor = SizeComparingLocalReleaseAuditor(
    repositoryRoot: invocation.repositoryRoot,
    driver: driver,
  );
  final finalizer = ReleaseFinalizer(
    repository: repository,
    signatures: signatures,
    localAuditor: auditor,
    alerts: ConsoleReleaseAlertSink(),
  );

  return finalizer.finalize(
    tag: invocation.tag,
    expectedFingerprint: invocation.expectedFingerprint,
    workingDirectory: invocation.workingDirectory,
  );
}

Directory _resolveDirectory(Directory base, String path) {
  if (p.isAbsolute(path)) return Directory(p.normalize(path)).absolute;

  return Directory(p.normalize(p.join(base.path, path))).absolute;
}

final RegExp _repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

final class _CommandArguments {
  final String repository;
  final String tag;
  final String fingerprint;
  final String repositoryRoot;

  const _CommandArguments({
    required this.repository,
    required this.tag,
    required this.fingerprint,
    required this.repositoryRoot,
  });

  static _CommandArguments? parse(List<String> arguments) {
    if (arguments.isEmpty || arguments.length.isOdd) return null;

    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      final option = arguments[index];
      if (!const {
        '--repository',
        '--tag',
        '--fingerprint',
        '--repo-root',
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
    final fingerprint = values['--fingerprint'];
    if (repository == null ||
        !_repositoryPattern.hasMatch(repository) ||
        tag == null ||
        !tag.startsWith('v') ||
        fingerprint == null) {
      return null;
    }

    return _CommandArguments(
      repository: repository,
      tag: tag,
      fingerprint: fingerprint,
      repositoryRoot: values['--repo-root'] ?? '.',
    );
  }
}

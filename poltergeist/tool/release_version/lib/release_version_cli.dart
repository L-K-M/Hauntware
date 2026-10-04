import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_version.dart';

const int _successExitCode = 0;
const int _failureExitCode = 1;
const int _usageExitCode = 64;
const String _usage =
    'usage: release_version <validate|sync|check|check-tag|check-order> '
    '[--version VERSION] [--pubspec PATH] [--tag TAG] '
    '[--prior-tag TAG]... [--root PATH]';

typedef ReleaseVersionLineWriter = void Function(String line);

/// Runs the deterministic release-version command without exiting the process.
int runReleaseVersionCommand(
  List<String> arguments, {
  Directory? workingDirectory,
  ReleaseVersionLineWriter? writeOutput,
  ReleaseVersionLineWriter? writeError,
}) {
  final ReleaseVersionLineWriter output = writeOutput ?? stdout.writeln;
  final ReleaseVersionLineWriter error = writeError ?? stderr.writeln;
  final parsed = _CommandArguments.parse(arguments);
  if (parsed == null) {
    error(_usage);
    return _usageExitCode;
  }

  try {
    final base = workingDirectory ?? Directory.current;
    final root = _resolveDirectory(base, parsed.root ?? '.');

    // Inside the Hauntware monorepo the module-scoped tree checks can't
    // resolve the app's path dependencies — they point at sibling module
    // trees. Forward tree checks to the suite tool at the actual root.
    if (_forwardsToSuite(parsed.command)) {
      final suite = _findSuiteRoot(root);
      if (suite != null) {
        return _forwardToSuite(suite, arguments, output: output, error: error);
      }
    }

    switch (parsed.command) {
      case _ReleaseVersionCommand.validate:
        final version = ReleaseVersion.parse(parsed.version!);
        output(version.appVersion);
      case _ReleaseVersionCommand.sync:
        final version = ReleaseVersion.parse(parsed.version!);
        ReleaseVersionWorkspace(
          root,
        ).syncAppMetadata(version: version, pubspecPath: parsed.pubspec!);
        output('Synced app metadata to ${version.appVersion}');
      case _ReleaseVersionCommand.check:
        final expected = parsed.version == null
            ? null
            : ReleaseVersion.parse(parsed.version!);
        final report = ReleaseVersionWorkspace(root).check(expected: expected);
        output(_renderReport(report));
      case _ReleaseVersionCommand.checkTag:
        final report = ReleaseVersionWorkspace(root).checkTag(parsed.tag!);
        output('${parsed.tag}: ${_renderReport(report)}');
      case _ReleaseVersionCommand.checkOrder:
        final target = parsed.version == null
            ? null
            : ReleaseVersion.parse(parsed.version!);
        final checked = ReleaseVersionWorkspace(
          root,
        ).checkReleaseOrder(target: target, priorTags: parsed.priorTags);
        output('${checked.appVersion} preserves release order');
    }

    return _successExitCode;
  } on ReleaseVersionFormatException catch (exception) {
    error(exception.message);
    return _failureExitCode;
  } on ReleaseVersionStateException catch (exception) {
    error(exception.message);
    return _failureExitCode;
  } on FileSystemException catch (exception) {
    error(exception.toString());
    return _failureExitCode;
  }
}

String _renderReport(ReleaseVersionReport report) {
  return '${report.version.appVersion} synchronized across '
      '${report.pubspecCount} pubspecs and '
      '${report.lockedPackageCount} path locks';
}

Directory _resolveDirectory(Directory base, String path) {
  if (p.isAbsolute(path)) return Directory(p.normalize(path));

  return Directory(p.normalize(p.join(base.path, path)));
}

const String _suiteToolPath = 'tool/release_version/bin/release_version.dart';
final RegExp _suiteManifestName = RegExp(
  r'^name:[ \t]*hauntware[ \t]*$',
  multiLine: true,
);

bool _forwardsToSuite(_ReleaseVersionCommand command) => switch (command) {
  _ReleaseVersionCommand.check ||
  _ReleaseVersionCommand.checkTag ||
  _ReleaseVersionCommand.checkOrder => true,
  _ => false,
};

/// The Hauntware suite root enclosing [root], if any: an ancestor whose
/// `poltergeist/` module contains [root], that carries the suite tool
/// and a `hauntware` manifest.
Directory? _findSuiteRoot(Directory root) {
  final rootPath = p.normalize(root.absolute.path);
  var candidate = p.dirname(rootPath);
  while (true) {
    final module = p.join(candidate, 'poltergeist');
    if ((p.isWithin(module, rootPath) || p.equals(module, rootPath)) &&
        File(p.join(candidate, _suiteToolPath)).existsSync() &&
        _isSuiteManifest(File(p.join(candidate, 'pubspec.yaml')))) {
      return Directory(candidate);
    }

    final parent = p.dirname(candidate);
    if (p.equals(parent, candidate)) return null;
    candidate = parent;
  }
}

bool _isSuiteManifest(File pubspec) {
  if (!pubspec.existsSync()) return false;
  return _suiteManifestName.hasMatch(pubspec.readAsStringSync());
}

/// Runs the suite tool against the suite root, forwarding the command
/// and its output verbatim. Any `--root` is replaced — the suite check
/// always evaluates the whole suite.
int _forwardToSuite(
  Directory suite,
  List<String> arguments, {
  required ReleaseVersionLineWriter output,
  required ReleaseVersionLineWriter error,
}) {
  final forwarded = <String>[];
  var skipValue = false;
  for (final argument in arguments) {
    if (skipValue) {
      skipValue = false;
      continue;
    }
    if (argument == '--root') {
      skipValue = true;
      continue;
    }
    forwarded.add(argument);
  }
  forwarded.addAll(['--root', suite.path]);

  final result = Process.runSync(Platform.resolvedExecutable, [
    p.join(suite.path, _suiteToolPath),
    ...forwarded,
  ]);
  final stdout = (result.stdout as String).trimRight();
  final stderr = (result.stderr as String).trimRight();
  if (stdout.isNotEmpty) output(stdout);
  if (stderr.isNotEmpty) error(stderr);
  return result.exitCode;
}

enum _ReleaseVersionCommand { validate, sync, check, checkTag, checkOrder }

final class _CommandArguments {
  final _ReleaseVersionCommand command;
  final String? version;
  final String? pubspec;
  final String? tag;
  final List<String> priorTags;
  final String? root;

  const _CommandArguments({
    required this.command,
    required this.version,
    required this.pubspec,
    required this.tag,
    required this.priorTags,
    required this.root,
  });

  static _CommandArguments? parse(List<String> arguments) {
    if (arguments.isEmpty) return null;

    final command = switch (arguments.first) {
      'validate' => _ReleaseVersionCommand.validate,
      'sync' => _ReleaseVersionCommand.sync,
      'check' => _ReleaseVersionCommand.check,
      'check-tag' => _ReleaseVersionCommand.checkTag,
      'check-order' => _ReleaseVersionCommand.checkOrder,
      _ => null,
    };
    if (command == null) return null;

    final values = <String, String>{};
    final priorTags = <String>[];
    for (var index = 1; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length) return null;

      final option = arguments[index];
      if (!const {
        '--version',
        '--pubspec',
        '--tag',
        '--prior-tag',
        '--root',
      }.contains(option)) {
        return null;
      }
      if (arguments[index + 1].startsWith('--')) return null;

      if (option == '--prior-tag') {
        priorTags.add(arguments[index + 1]);
        continue;
      }
      if (values.containsKey(option)) return null;

      values[option] = arguments[index + 1];
    }

    final parsed = _CommandArguments(
      command: command,
      version: values['--version'],
      pubspec: values['--pubspec'],
      tag: values['--tag'],
      priorTags: List.unmodifiable(priorTags),
      root: values['--root'],
    );
    return parsed._hasValidShape ? parsed : null;
  }

  bool get _hasValidShape {
    final present = <String>{
      if (version != null) '--version',
      if (pubspec != null) '--pubspec',
      if (tag != null) '--tag',
      if (priorTags.isNotEmpty) '--prior-tag',
      if (root != null) '--root',
    };

    return switch (command) {
      _ReleaseVersionCommand.validate =>
        version != null &&
            present.difference(const {'--version', '--root'}).isEmpty,
      _ReleaseVersionCommand.sync =>
        version != null &&
            pubspec != null &&
            present.difference(const {
              '--version',
              '--pubspec',
              '--root',
            }).isEmpty,
      _ReleaseVersionCommand.check => present.difference(const {
        '--version',
        '--root',
      }).isEmpty,
      _ReleaseVersionCommand.checkTag =>
        tag != null && present.difference(const {'--tag', '--root'}).isEmpty,
      _ReleaseVersionCommand.checkOrder => present.difference(const {
        '--version',
        '--prior-tag',
        '--root',
      }).isEmpty,
    };
  }
}

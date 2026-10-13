import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Stable workflow marker guarded by CI whenever a Séance pin exists.
const String seanceLicenseGateMarker = 'SEANCE_LICENSE_GATE_V1';

const String _releaseWorkflowPath = '.github/workflows/release.yml';
const String _gateInvocation = 'dart run tool/license_gate/bin/check.dart';
const String _releaseAction = 'softprops/action-gh-release@';
const String _imagePushAction = 'docker/build-push-action@';
const String _spdxRepository = 'https://github.com/spdx/license-list-data.git';
const String _spdxRevision = 'c4a7237ec8f4654e867546f9f409749300f1bf4c';
const Set<String> _permittedLicenseIds = {
  'Unlicense',
  'MIT',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'ISC',
};
const Set<String> _licenseFileNames = {
  'LICENSE',
  'LICENSE.txt',
  'LICENSE.md',
  'LICENCE',
  'UNLICENSE',
  'COPYING',
};
const Set<String> _seancePackageNames = {'seance_core', 'seance_protocol'};
const String _seanceComponent = 'seance';
const Set<String> _permittedCopyrightHolders = {'L-K-M'};
const Set<String> _vendoredDirectoryNames = {
  'third_party',
  'third-party',
  'vendor',
  'vendors',
  'node_modules',
  'ext',
  'external',
  'deps',
};
const Set<String> _ignoredDirectoryNames = {
  '.dart_tool',
  '.git',
  '.plugin_symlinks',
  '.symlinks',
  'build',
  'ephemeral',
  'Pods',
};

final RegExp _gitRevisionPattern = RegExp(r'^[0-9a-fA-F]{40,64}$');
final RegExp _copyrightPrefixPattern = RegExp(
  r'^\s*(?:[#*;/<>\-]+\s*)?copyright\s*:?\s*',
  caseSensitive: false,
);
final RegExp _copyrightYearPattern = RegExp(
  r'^(?:\d{4}|\[yyyy\]|<year>)(?:\s*[-–,]\s*\d{2,4})?(?:\s+|$)',
  caseSensitive: false,
);
const Set<String> _copyrightPlaceholders = {
  '<copyright holder>',
  '<copyright holders>',
  '<owner>',
  '[name of copyright owner]',
};

enum LicenseGateMode {
  /// Checks the CI marker and declaration-to-lock resolution only.
  markerOnly,

  /// Also validates every resolved component tree against the SPDX
  /// allowlist.
  release,
}

/// Sources are injectable so gate tests stay local and deterministic.
final class LicenseGateSettings {
  final String spdxRepository;
  final String spdxRevision;
  final Set<String> permittedLicenseIds;
  final Set<String> permittedCopyrightHolders;

  const LicenseGateSettings({
    this.spdxRepository = _spdxRepository,
    this.spdxRevision = _spdxRevision,
    this.permittedLicenseIds = _permittedLicenseIds,
    this.permittedCopyrightHolders = _permittedCopyrightHolders,
  });
}

final class LicenseGateReport {
  final int declarationCount;
  final int lockedSourceCount;
  final Set<String> matchedLicenseIds;

  const LicenseGateReport({
    required this.declarationCount,
    required this.lockedSourceCount,
    required this.matchedLicenseIds,
  });
}

final class LicenseGateException implements Exception {
  final String message;

  const LicenseGateException(this.message);

  @override
  String toString() => message;
}

/// Verifies the D30 marker, lock resolution, and the licenses of the local
/// Séance component sources those locks resolve.
Future<LicenseGateReport> verifySeanceLicenseGate({
  required Directory repositoryRoot,
  required LicenseGateMode mode,
  LicenseGateSettings settings = const LicenseGateSettings(),
}) async {
  final root = Directory(p.normalize(p.absolute(repositoryRoot.path)));
  if (!root.existsSync()) {
    throw LicenseGateException('repository root does not exist: ${root.path}');
  }

  final pubspecFiles = _findFiles(root, 'pubspec.yaml');
  final lockFiles = _findFiles(root, 'pubspec.lock');
  final worktree = await _worktreeRoot(root);
  final declarations = <_LocalDeclaration>[
    for (final pubspec in pubspecFiles) ..._readDeclarations(pubspec, worktree),
  ];
  final workspaceLocks = _readWorkspaceLocks(pubspecFiles);
  final locks = <String, _LockFile>{
    for (final file in lockFiles)
      p.normalize(p.absolute(file.path)): _readLock(file, worktree),
  };

  _verifyDeclarationResolution(declarations, locks, workspaceLocks);

  final sources = <_LocalPin>{
    for (final lock in locks.values) ...lock.seanceSources,
  };
  await _verifyCommittedLocks(root, declarations, locks, workspaceLocks);
  _verifyWorkflowGate(
    root,
    worktree,
    declarations.isNotEmpty || sources.isNotEmpty,
  );

  if (mode == LicenseGateMode.markerOnly || sources.isEmpty) {
    return LicenseGateReport(
      declarationCount: declarations.length,
      lockedSourceCount: sources.length,
      matchedLicenseIds: const {},
    );
  }

  final canonical = await _loadCanonicalLicenses(settings);
  final matchedLicenseIds = <String>{};
  final components = <String>{
    for (final source in sources) source.componentRel,
  };
  for (final componentRel in components.toList()..sort()) {
    final tree = _ComponentTree(worktree!, componentRel);
    await tree.requireClean();
    final found = <String>[];
    for (final candidate in await tree.licenseFiles()) {
      final text = await tree.read(candidate.path);
      if (text == null) continue;

      found.add(candidate.path);
      final licenseId = _matchLicense(
        text,
        canonical,
        candidate.vendored ? const {} : settings.permittedCopyrightHolders,
        allowAnyCopyrightHolder: candidate.vendored,
      );
      if (licenseId == null) {
        throw LicenseGateException(
          '$componentRel has a non-permitted ${candidate.path}',
        );
      }
      matchedLicenseIds.add(licenseId);
    }

    if (found.isEmpty) {
      throw LicenseGateException(
        'the $componentRel component has no recognized license file',
      );
    }
  }

  return LicenseGateReport(
    declarationCount: declarations.length,
    lockedSourceCount: sources.length,
    matchedLicenseIds: matchedLicenseIds,
  );
}

/// The gate runs against the worktree that contains the scan root, so a
/// component directory (for example `poltergeist/` inside the monorepo)
/// resolves against the monorepo toplevel while a standalone project keeps
/// working as its own toplevel.
Future<Directory?> _worktreeRoot(Directory root) async {
  final result = await Process.run(
    'git',
    ['-C', root.path, 'rev-parse', '--show-toplevel'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) return null;

  final toplevel = p.normalize(
    await Directory('${result.stdout}'.trim()).resolveSymbolicLinks(),
  );
  final resolvedRoot = p.normalize(await root.resolveSymbolicLinks());
  if (resolvedRoot != toplevel && !p.isWithin(toplevel, resolvedRoot)) {
    throw LicenseGateException(
      'repository root escapes its Git worktree: ${root.path}',
    );
  }

  return Directory(toplevel);
}

bool _isWithinWorktree(Directory worktree, String resolved) =>
    p.equals(worktree.path, resolved) || p.isWithin(worktree.path, resolved);

/// The top-level component a worktree path belongs to, or null outside it.
String? _componentOf(Directory worktree, String resolved) {
  if (!_isWithinWorktree(worktree, resolved) ||
      p.equals(worktree.path, resolved)) {
    return null;
  }
  final segments = p.split(p.relative(resolved, from: worktree.path));
  if (segments.isEmpty) return null;

  return segments.first;
}

/// Séance sources are local path dependencies that resolve inside this
/// worktree's `seance/` component, or packages whose names claim the
/// `seance_` prefix. Anything else — a git pin, a hosted version, a path
/// escaping the worktree or the component — is a fail-closed violation.
List<File> _findFiles(Directory root, String fileName) {
  final found = <File>[];
  final pending = <Directory>[root];

  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        if (name == '.git') {
          continue;
        }
        if (_ignoredDirectoryNames.contains(name) &&
            !_containsTrackedFiles(root, entity)) {
          continue;
        }

        pending.add(entity);
        continue;
      }
      if (entity is Link) {
        final targetType = FileSystemEntity.typeSync(
          entity.path,
          followLinks: true,
        );
        if (p.basename(entity.path) != fileName &&
            targetType != FileSystemEntityType.directory) {
          continue;
        }

        throw LicenseGateException(
          '${entity.path}: dependency trees must not use symbolic links',
        );
      }
      if (entity is File && p.basename(entity.path) == fileName) {
        found.add(entity);
      }
    }
  }

  found.sort((left, right) => left.path.compareTo(right.path));
  return found;
}

bool _containsTrackedFiles(Directory root, Directory directory) {
  final relativePath = p
      .relative(directory.path, from: root.path)
      .replaceAll('\\', '/');
  final result = Process.runSync(
    'git',
    ['-C', root.path, 'ls-files', '--', relativePath],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode == 0) {
    return (result.stdout as String).trim().isNotEmpty;
  }

  throw LicenseGateException(
    'git ls-files failed: ${(result.stderr as String).trim()}',
  );
}

List<_LocalDeclaration> _readDeclarations(File pubspec, Directory? worktree) {
  final document = _readYamlMap(pubspec);
  final declarations = <_LocalDeclaration>[];

  for (final sectionName in const {
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  }) {
    final section = _asMap(document[sectionName]);
    if (section == null) continue;

    for (final entry in section.entries) {
      final packageName = entry.key;
      final specification = _asMap(entry.value);
      if (packageName is! String) continue;

      if (specification == null) {
        if (_isSeancePackage(packageName)) {
          throw LicenseGateException(
            '${pubspec.path}: $packageName must use a local path source',
          );
        }
        continue;
      }

      final git = specification['git'];
      if (git != null) {
        final url = switch (git) {
          final String value => value,
          final Map<Object?, Object?> value => value['url'],
          _ => null,
        };
        if (url is! String && !_isSeancePackage(packageName)) continue;
        if (url is String && !_isSeanceDependency(packageName, url)) {
          continue;
        }

        throw LicenseGateException(
          '${pubspec.path}: $packageName resolves from an external git '
          'source; Séance packages must use a local path dependency',
        );
      }

      final declaredPath = specification['path'];
      if (declaredPath is! String || declaredPath.isEmpty) {
        if (_isSeancePackage(packageName)) {
          throw LicenseGateException(
            '${pubspec.path}: $packageName must use a local path source',
          );
        }
        continue;
      }

      final resolved = p.normalize(
        p.isAbsolute(declaredPath)
            ? declaredPath
            : p.join(pubspec.parent.path, declaredPath),
      );
      final componentRel = worktree == null
          ? null
          : _componentOf(worktree, resolved);
      if (!_isSeancePackage(packageName) && componentRel != _seanceComponent) {
        continue;
      }
      if (worktree == null) {
        throw LicenseGateException(
          '${pubspec.path}: $packageName resolves outside a Git worktree',
        );
      }
      if (!_isWithinWorktree(worktree, resolved)) {
        throw LicenseGateException(
          '${pubspec.path}: $packageName resolves outside the worktree',
        );
      }
      if (componentRel != _seanceComponent) {
        throw LicenseGateException(
          '${pubspec.path}: $packageName resolves outside the '
          '$_seanceComponent component',
        );
      }

      declarations.add(
        _LocalDeclaration(
          packageName: packageName,
          pubspec: pubspec,
          resolved: resolved,
          componentRel: componentRel!,
        ),
      );
    }
  }

  return declarations;
}

_LockFile _readLock(File file, Directory? worktree) {
  final document = _readYamlMap(file);
  final packages = _asMap(document['packages']);
  if (packages == null) {
    throw LicenseGateException('${file.path}: missing packages map');
  }

  final sources = <_LocalPin>[];
  for (final entry in packages.entries) {
    final packageName = entry.key;
    final specification = _asMap(entry.value);
    if (packageName is! String || specification == null) continue;
    final source = specification['source'];
    if (source == 'git') {
      final description = _asMap(specification['description']);
      final url = description?['url'];
      if (url is String && !_isSeanceDependency(packageName, url)) continue;
      if (url is! String && !_isSeancePackage(packageName)) continue;

      throw LicenseGateException(
        '${file.path}: $packageName pins an external git source',
      );
    }
    if (source != 'path') {
      if (_isSeancePackage(packageName)) {
        throw LicenseGateException(
          '${file.path}: $packageName resolves from an unexpected source',
        );
      }
      continue;
    }

    final description = _asMap(specification['description']);
    final resolved = _resolveLockPath(file, description);
    final componentRel = worktree == null || resolved == null
        ? null
        : _componentOf(worktree, resolved);
    if (!_isSeancePackage(packageName) && componentRel != _seanceComponent) {
      continue;
    }
    if (worktree == null || resolved == null) {
      throw LicenseGateException(
        '${file.path}: $packageName has no usable path resolution',
      );
    }
    if (!_isWithinWorktree(worktree, resolved)) {
      throw LicenseGateException(
        '${file.path}: $packageName resolves outside the worktree',
      );
    }
    if (componentRel != _seanceComponent) {
      throw LicenseGateException(
        '${file.path}: $packageName resolves outside the '
        '$_seanceComponent component',
      );
    }

    sources.add(
      _LocalPin(
        packageName: packageName,
        resolved: resolved,
        componentRel: componentRel!,
      ),
    );
  }

  return _LockFile(file: file, packages: packages, seanceSources: sources);
}

String? _resolveLockPath(File lock, Map<Object?, Object?>? description) {
  final path = description?['path'];
  if (path is! String || path.isEmpty) return null;
  final relative = description?['relative'];
  if (p.isAbsolute(path)) return p.normalize(path);
  // `relative: false` marks an absolute path; a non-absolute value here is
  // not a usable resolution.
  if (relative is bool && !relative) return null;

  return p.normalize(p.join(lock.parent.path, path));
}

void _verifyDeclarationResolution(
  List<_LocalDeclaration> declarations,
  Map<String, _LockFile> locks,
  Map<String, String> workspaceLocks,
) {
  for (final declaration in declarations) {
    final lockPath = _lockPathForDeclaration(declaration, workspaceLocks);
    final lock = locks[p.normalize(lockPath)];
    if (lock == null) {
      throw LicenseGateException(
        '${declaration.pubspec.path}: ${declaration.packageName} is not '
        'covered by a pubspec.lock',
      );
    }

    final specification = _asMap(lock.packages[declaration.packageName]);
    final resolved = _resolveLockPath(
      lock.file,
      _asMap(specification?['description']),
    );
    if (specification?['source'] == 'path' &&
        resolved == declaration.resolved) {
      continue;
    }

    throw LicenseGateException(
      '${declaration.pubspec.path}: ${declaration.packageName} is not '
      'resolved by ${lock.file.path}',
    );
  }
}

String _lockPathForDeclaration(
  _LocalDeclaration declaration,
  Map<String, String> workspaceLocks,
) {
  final pubspecDirectory = p.normalize(
    p.absolute(declaration.pubspec.parent.path),
  );
  return workspaceLocks[pubspecDirectory] ??
      p.join(pubspecDirectory, 'pubspec.lock');
}

Map<String, String> _readWorkspaceLocks(List<File> pubspecFiles) {
  final locks = <String, String>{};
  for (final pubspec in pubspecFiles) {
    final document = _readYamlMap(pubspec);
    final members = _asList(document['workspace']);
    if (members == null) continue;

    final workspaceRoot = p.normalize(p.absolute(pubspec.parent.path));
    final lockPath = p.join(workspaceRoot, 'pubspec.lock');
    for (final member in members) {
      if (member is! String) continue;

      final memberPath = p.normalize(p.join(workspaceRoot, member));
      final previous = locks[memberPath];
      if (previous != null && previous != lockPath) {
        throw LicenseGateException(
          '$memberPath belongs to more than one pub workspace',
        );
      }
      locks[memberPath] = lockPath;
    }
  }
  return locks;
}

Future<void> _verifyCommittedLocks(
  Directory root,
  List<_LocalDeclaration> declarations,
  Map<String, _LockFile> locks,
  Map<String, String> workspaceLocks,
) async {
  final relevantPaths = <String>{
    for (final declaration in declarations)
      p.normalize(_lockPathForDeclaration(declaration, workspaceLocks)),
    for (final lock in locks.values)
      if (lock.seanceSources.isNotEmpty)
        p.normalize(p.absolute(lock.file.path)),
  };
  if (relevantPaths.isEmpty) return;

  final topLevel = (await _runRepositoryGit(root, const [
    'rev-parse',
    '--show-toplevel',
  ])).trim();
  final resolvedTopLevel = p.normalize(
    await Directory(topLevel).resolveSymbolicLinks(),
  );
  if (resolvedTopLevel != root.path &&
      !p.isWithin(resolvedTopLevel, root.path)) {
    throw const LicenseGateException(
      'repository root escapes the Git worktree root',
    );
  }

  for (final lockPath in relevantPaths) {
    final relativePath = p
        .relative(lockPath, from: root.path)
        .replaceAll('\\', '/');
    final tracked = await Process.run(
      'git',
      ['-C', root.path, 'ls-files', '--error-unmatch', '--', relativePath],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final status = await _runRepositoryGit(root, [
      'status',
      '--porcelain=v1',
      '--untracked-files=all',
      '--',
      relativePath,
    ]);
    if (tracked.exitCode == 0 && status.trim().isEmpty) continue;

    throw LicenseGateException(
      '$relativePath must be committed and clean after dependency resolution',
    );
  }
}

Future<String> _runRepositoryGit(Directory root, List<String> arguments) async {
  final result = await Process.run(
    'git',
    ['-C', root.path, ...arguments],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode == 0) return result.stdout as String;

  throw LicenseGateException(
    'git ${arguments.first} failed: ${(result.stderr as String).trim()}',
  );
}

void _verifyWorkflowGate(Directory root, Directory? worktree, bool required) {
  // The release pipeline lives at the worktree toplevel: inside the
  // monorepo that is the root `.github`, while a standalone repository is
  // its own toplevel.
  final base = worktree ?? root;
  final workflow = File(p.join(base.path, _releaseWorkflowPath));
  if (!workflow.existsSync()) {
    if (!required) return;

    throw const LicenseGateException(
      'release.yml is missing the required Séance license gate',
    );
  }

  final text = workflow.readAsStringSync();
  final mentionsGate =
      text.contains(seanceLicenseGateMarker) || text.contains(_gateInvocation);
  if (!required && !mentionsGate) return;
  final markerPattern = RegExp(
    '^\\s*(?:-\\s+)?run:\\s*${RegExp.escape(_gateInvocation)}\\s+'
    '#\\s*${RegExp.escape(seanceLicenseGateMarker)}\\s*\$',
    multiLine: true,
  );
  if (markerPattern.allMatches(text).length != 1) {
    throw const LicenseGateException(
      'release.yml is missing the required active license-gate marker',
    );
  }

  final document = _readYamlMap(workflow);
  final jobs = _asMap(document['jobs']);
  if (jobs == null) {
    throw const LicenseGateException('release.yml has no jobs map');
  }

  String? gateJobName;
  int? gateStepIndex;
  var gateJobCount = 0;
  for (final entry in jobs.entries) {
    final jobName = entry.key;
    final job = _asMap(entry.value);
    if (jobName is! String || job == null) continue;

    final steps = _asList(job['steps']);
    if (steps == null) continue;
    var dependencyResolutionSeen = false;
    var gateSeen = false;
    for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final stepValue = steps[stepIndex];
      final step = _asMap(stepValue);
      if (step == null) continue;

      final run = step['run'];
      if (run is! String) continue;
      // A post-gate `flutter build` (pub enabled) is allowed: it
      // resolves against the committed lock, which cannot drift the
      // pin the gate just verified, and the tool needs the build's
      // own resolution to regenerate GeneratedPluginRegistrant for
      // the release dependency set (--no-pub twice failed android
      // release javac on the dev-dep integration_test entry).
      if (gateSeen && _runsDependencyResolution(run)) {
        throw const LicenseGateException(
          'release.yml resolves dependencies after the license gate',
        );
      }
      if (_runsDependencyResolution(run)) dependencyResolutionSeen = true;
      if (run.trim() != _gateInvocation) continue;

      gateSeen = true;
      gateJobCount += 1;
      gateJobName = jobName;
      gateStepIndex = stepIndex;
      if (job['if'] != null ||
          job['continue-on-error'] != null ||
          step['if'] != null ||
          step['continue-on-error'] != null) {
        throw const LicenseGateException(
          'release.yml license gate must be unconditional and fail closed',
        );
      }
      if (!dependencyResolutionSeen) {
        throw const LicenseGateException(
          'release.yml runs the license gate before dependency resolution',
        );
      }
    }
  }
  if (gateJobCount != 1 || gateJobName == null || gateStepIndex == null) {
    throw const LicenseGateException(
      'release.yml must contain exactly one license-gate invocation',
    );
  }

  final directNeeds = <String, Set<String>>{};
  for (final entry in jobs.entries) {
    final jobName = entry.key;
    final job = _asMap(entry.value);
    if (jobName is! String || job == null) continue;
    directNeeds[jobName] = _jobNeeds(job);
  }

  for (final entry in jobs.entries) {
    final jobName = entry.key;
    final job = _asMap(entry.value);
    if (jobName is! String || job == null) continue;
    final steps = _asList(job['steps']);
    if (steps == null) continue;
    // A job skipped by `needs` on a failed gate can never reach its
    // publish step; the transitive closure covers needs chains of any
    // depth (build legs behind the flip job, and so on).
    final needsReachGate = _transitiveNeeds(
      jobName,
      directNeeds,
    ).contains(gateJobName);
    for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final step = _asMap(steps[stepIndex]);
      if (step == null) continue;
      final surface = _releaseSurface(step);
      if (surface == _ReleaseSurface.none) continue;

      if (job['if'] != null ||
          job['continue-on-error'] != null ||
          step['if'] != null ||
          step['continue-on-error'] != null) {
        throw LicenseGateException(
          'release publisher job $jobName can bypass failed prerequisites',
        );
      }
      // Draft-only attachments are inert while the release stays hidden:
      // the surfaces that expose anything (a non-draft release upload,
      // the draft flip, a registry push) carry the gating requirement.
      if (surface == _ReleaseSurface.attach) continue;
      final gated = jobName == gateJobName
          ? stepIndex > gateStepIndex
          : needsReachGate;
      if (gated) continue;

      throw LicenseGateException(
        'release publisher job $jobName bypasses the license gate',
      );
    }
  }
}

enum _ReleaseSurface { none, attach, publish }

/// Whether a workflow step can expose release artifacts publicly:
/// attaching files to the hidden draft is inert, while publishing the
/// release, flipping its draft flag, or pushing an image is not.
_ReleaseSurface _releaseSurface(Map<Object?, Object?> step) {
  final uses = step['uses'];
  if (uses is String) {
    if (uses.startsWith(_releaseAction)) {
      final withMap = _asMap(step['with']);
      return _isTruthy(withMap?['draft'])
          ? _ReleaseSurface.attach
          : _ReleaseSurface.publish;
    }
    if (uses.startsWith(_imagePushAction)) {
      final withMap = _asMap(step['with']);
      final push = withMap?['push'];
      if (push == null || push == false || push == 'false') {
        return _ReleaseSurface.none;
      }
      return _ReleaseSurface.publish;
    }
    return _ReleaseSurface.none;
  }
  final run = step['run'];
  if (run is String && _runsReleasePublish(run)) {
    return _ReleaseSurface.publish;
  }
  return _ReleaseSurface.none;
}

bool _isTruthy(Object? value) => value == true || value == 'true';

/// Publish commands embedded in `run` scripts: `gh release create`
/// without a draft flag, `gh release edit --draft=false` (the flip),
/// `gh api` calls that mutate `draft`, and Docker pushes.
bool _runsReleasePublish(String command) {
  final editFlip = RegExp(
    r'\bgh\s+release\s+edit\b[^\n]*--draft\s*[= ]\s*false\b',
  );
  final create = RegExp(r'\bgh\s+release\s+create\b');
  // `--draft` keeps `gh release create` hidden unless it is explicitly
  // set to a false value (`--draft=false`, `--draft false`).
  final draftKeeps = RegExp(r'''--draft(?!\s*[= ]\s*["']?false\b)''');
  final apiDraft = RegExp(r'\bgh\s+api\b[^\n]*\bdraft\b');
  final dockerPush = RegExp(
    r'\bdocker\s+(?:push\b|(?:buildx\s+)?build\b[^\n]*--push\b)',
  );

  // Fold backslash continuations first so a flag cannot hide on the
  // next physical line of a `run: |` block.
  final logical = command.replaceAll(RegExp(r'\\\r?\n'), ' ');
  for (final rawLine in logical.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (editFlip.hasMatch(line) ||
        apiDraft.hasMatch(line) ||
        dockerPush.hasMatch(line)) {
      return true;
    }
    if (create.hasMatch(line) && !draftKeeps.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

Set<String> _jobNeeds(Map<Object?, Object?> job) {
  final needs = job['needs'];
  if (needs is String) return {needs};
  final list = _asList(needs);
  if (list == null) return const {};
  return {
    for (final need in list)
      if (need is String) need,
  };
}

Set<String> _transitiveNeeds(String job, Map<String, Set<String>> direct) {
  final seen = <String>{};
  final queue = [...?direct[job]];
  while (queue.isNotEmpty) {
    final need = queue.removeLast();
    if (seen.add(need)) queue.addAll(direct[need] ?? const {});
  }
  return seen;
}

bool _runsDependencyResolution(String command) {
  final pubGet = RegExp(
    r'^(?!\s*#).*\b(?:dart|flutter)\s+pub\s+(?:get|upgrade|add|remove|downgrade)\b',
  );
  return command
      .split(RegExp(r'\r?\n'))
      .any((line) => pubGet.hasMatch(line.trim()));
}

Future<Map<String, String>> _loadCanonicalLicenses(
  LicenseGateSettings settings,
) async {
  if (!_gitRevisionPattern.hasMatch(settings.spdxRevision)) {
    throw const LicenseGateException('SPDX revision must be a full commit');
  }

  final snapshot = await _GitSnapshot.fetch(
    settings.spdxRepository,
    settings.spdxRevision,
  );
  try {
    final canonical = <String, String>{};
    for (final licenseId in settings.permittedLicenseIds) {
      final text = await snapshot.read('text/$licenseId.txt');
      if (text == null) {
        throw LicenseGateException(
          'SPDX revision is missing text/$licenseId.txt',
        );
      }
      canonical[licenseId] = _normalizeLicense(
        text,
        copyrightSource: _CopyrightSource.canonical,
      );
    }
    return canonical;
  } finally {
    await snapshot.dispose();
  }
}

String? _matchLicense(
  String text,
  Map<String, String> canonical,
  Set<String> permittedCopyrightHolders, {
  bool allowAnyCopyrightHolder = false,
}) {
  final normalized = _normalizeLicense(
    text,
    copyrightSource: allowAnyCopyrightHolder
        ? _CopyrightSource.canonical
        : _CopyrightSource.candidate,
    permittedCopyrightHolders: permittedCopyrightHolders,
  );
  for (final entry in canonical.entries) {
    if (entry.value == normalized) return entry.key;
  }
  return null;
}

enum _CopyrightSource { canonical, candidate }

String _normalizeLicense(
  String text, {
  required _CopyrightSource copyrightSource,
  Set<String> permittedCopyrightHolders = const {},
}) {
  final withoutBom = text.startsWith('\ufeff') ? text.substring(1) : text;
  final lines = withoutBom.split(RegExp(r'\r\n?|\n'));
  final substantive = lines
      .where(
        (line) => !_isCopyrightNotice(
          line,
          copyrightSource,
          permittedCopyrightHolders,
        ),
      )
      .toList();
  // License files conventionally open with a bare title line; only the
  // exact titles the SPDX corpus prints for the permitted ids (plus the
  // vendored spellings actually in use) may be dropped — a restricted or
  // foreign heading like "MIT License - Non-Commercial Only" stays part
  // of the body comparison and fails closed.
  for (var index = 0; index < substantive.length; index++) {
    if (substantive[index].trim().isEmpty) continue;
    if (_licenseTitles.contains(substantive[index].trim().toLowerCase())) {
      substantive.removeAt(index);
    }
    break;
  }
  return substantive.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Title lines the SPDX corpus prints for the permitted licenses plus
/// the vendored variants in the tree (`The MIT License (MIT)`).
const _licenseTitles = {
  'apache license',
  'bsd 2-clause license',
  'bsd 3-clause license',
  'isc license',
  'mit license',
  'the mit license (mit)',
};

bool _isCopyrightNotice(
  String line,
  _CopyrightSource source,
  Set<String> permittedCopyrightHolders,
) {
  final prefix = _copyrightPrefixPattern.firstMatch(line);
  if (prefix == null) return false;

  var remainder = line.substring(prefix.end).trim();
  var hasMarker = false;
  for (final marker in const ['(c)', '©']) {
    if (!remainder.toLowerCase().startsWith(marker)) continue;

    hasMarker = true;
    remainder = remainder.substring(marker.length).trimLeft();
    break;
  }

  final year = _copyrightYearPattern.firstMatch(remainder);
  if (year != null) remainder = remainder.substring(year.end).trim();
  if (!hasMarker && year == null) return false;

  remainder = remainder
      .replaceFirst(RegExp(r'\s*[#*;/<>\-]+\s*$'), '')
      .replaceFirst(
        RegExp(r'\.?\s+all rights reserved\.?$', caseSensitive: false),
        '',
      )
      .trim();
  if (source == _CopyrightSource.canonical) return true;
  if (remainder.isEmpty) return true;

  final placeholder = _normalizeCopyrightHolder(remainder);
  if (_copyrightPlaceholders.contains(placeholder)) return true;
  return permittedCopyrightHolders
      .map(_normalizeCopyrightHolder)
      .contains(placeholder);
}

String _normalizeCopyrightHolder(String holder) => holder
    .replaceFirst(RegExp(r'[.]$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

Map<Object?, Object?> _readYamlMap(File file) {
  try {
    final document = loadYaml(file.readAsStringSync());
    final mapping = _asMap(document);
    if (mapping != null) return mapping;
  } on Object catch (error) {
    throw LicenseGateException('${file.path}: invalid YAML: $error');
  }
  throw LicenseGateException('${file.path}: expected a YAML map');
}

Map<Object?, Object?>? _asMap(Object? value) {
  if (value is YamlMap) return value;
  if (value is Map<Object?, Object?>) return value;
  return null;
}

List<Object?>? _asList(Object? value) {
  if (value is YamlList) return value;
  if (value is List<Object?>) return value;
  return null;
}

bool _isSeancePackage(String packageName) =>
    _seancePackageNames.contains(packageName) ||
    packageName.startsWith('seance_');

bool _isSeanceDependency(String packageName, String url) {
  if (_isSeancePackage(packageName)) return true;

  final normalized = url.replaceAll('\\', '/').toLowerCase();
  return normalized.endsWith('/seance') ||
      normalized.endsWith('/seance.git') ||
      normalized == 'seance' ||
      normalized == 'seance.git';
}

final class _LocalDeclaration {
  final String packageName;
  final File pubspec;
  final String resolved;
  final String componentRel;

  const _LocalDeclaration({
    required this.packageName,
    required this.pubspec,
    required this.resolved,
    required this.componentRel,
  });
}

final class _LockFile {
  final File file;
  final Map<Object?, Object?> packages;
  final List<_LocalPin> seanceSources;

  const _LockFile({
    required this.file,
    required this.packages,
    required this.seanceSources,
  });
}

final class _LocalPin {
  final String packageName;
  final String resolved;
  final String componentRel;

  const _LocalPin({
    required this.packageName,
    required this.resolved,
    required this.componentRel,
  });

  @override
  bool operator ==(Object other) =>
      other is _LocalPin &&
      other.resolved == resolved &&
      other.packageName == packageName;

  @override
  int get hashCode => Object.hash(packageName, resolved);
}

/// A license file inside the component: first-party files carry the
/// project's copyright holder, while vendored files keep upstream holders
/// and erase notices against any holder.
final class _LicenseCandidate {
  final String path;
  final bool vendored;

  const _LicenseCandidate(this.path, this.vendored);
}

/// The committed component tree inside this worktree. License evidence is
/// read from `HEAD:<component>` objects — never from the working tree —
/// and the component must be clean so the resolved sources match exactly
/// what the gate certifies.
final class _ComponentTree {
  final Directory _worktree;
  final String _componentRel;

  const _ComponentTree(this._worktree, this._componentRel);

  Future<void> requireClean() async {
    final tree = await _runGit([
      'rev-parse',
      '--verify',
      'HEAD:$_componentRel',
    ]);
    if (!_gitRevisionPattern.hasMatch(tree.trim())) {
      throw LicenseGateException(
        'HEAD does not contain the $_componentRel component',
      );
    }
    final status = await _runGit([
      'status',
      '--porcelain=v1',
      '--untracked-files=all',
      '--',
      _componentRel,
    ]);
    if (status.trim().isNotEmpty) {
      throw LicenseGateException(
        'the $_componentRel component has uncommitted changes',
      );
    }
  }

  /// Component-root license names plus vendored license files under the
  /// vendored directory names, in deterministic tree order.
  Future<List<_LicenseCandidate>> licenseFiles() async {
    final listing = await _runGit([
      'ls-tree',
      '-r',
      '--name-only',
      'HEAD:$_componentRel',
    ]);
    final candidates = <_LicenseCandidate>[];
    for (final path in listing.split('\n')) {
      if (path.isEmpty) continue;
      final segments = p.posix.split(path);
      final name = segments.last;
      if (!_licenseFileNames.contains(name)) continue;
      if (segments.length == 1) {
        candidates.add(_LicenseCandidate(path, false));
        continue;
      }
      final vendored = segments
          .sublist(0, segments.length - 1)
          .any(_vendoredDirectoryNames.contains);
      if (vendored) candidates.add(_LicenseCandidate(path, true));
    }

    return candidates;
  }

  Future<String?> read(String path) async {
    final result = await Process.run(
      'git',
      ['-C', _worktree.path, 'show', 'HEAD:$_componentRel/$path'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) return result.stdout as String;

    final stderr = result.stderr as String;
    if (stderr.contains('does not exist in') ||
        stderr.contains('exists on disk, but not in')) {
      return null;
    }
    throw LicenseGateException('git show failed for $path: ${stderr.trim()}');
  }

  Future<String> _runGit(List<String> arguments) =>
      _runRepositoryGit(_worktree, arguments);
}

/// The canonical SPDX corpus still comes from the pinned upstream
/// repository — the gate's reference data, not a dependency source.
final class _GitSnapshot {
  final Directory _directory;

  const _GitSnapshot._(this._directory);

  static Future<_GitSnapshot> fetch(String url, String revision) async {
    if (!_gitRevisionPattern.hasMatch(revision)) {
      throw LicenseGateException(
        'Git revision must be a full commit: $revision',
      );
    }

    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-license-gate-',
    );
    try {
      await _runGit(directory, const ['init', '--quiet']);
      await _runGit(directory, ['remote', 'add', 'origin', url]);
      await _runGit(directory, [
        '-c',
        'protocol.file.allow=always',
        'fetch',
        '--quiet',
        '--depth=1',
        'origin',
        revision,
      ]);

      final resolved = (await _runGit(directory, const [
        'rev-parse',
        'FETCH_HEAD',
      ])).trim().toLowerCase();
      if (resolved != revision.toLowerCase()) {
        throw LicenseGateException(
          'Git fetched $resolved instead of requested $revision',
        );
      }
      return _GitSnapshot._(directory);
    } on Object {
      await _deleteTemporaryDirectory(directory);
      rethrow;
    }
  }

  Future<String?> read(String path) async {
    final result = await Process.run(
      'git',
      ['show', 'FETCH_HEAD:$path'],
      workingDirectory: _directory.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) return result.stdout as String;

    final stderr = result.stderr as String;
    if (stderr.contains('does not exist in') ||
        stderr.contains('exists on disk, but not in')) {
      return null;
    }
    throw LicenseGateException('git show failed for $path: ${stderr.trim()}');
  }

  Future<void> dispose() => _deleteTemporaryDirectory(_directory);

  static Future<String> _runGit(
    Directory directory,
    List<String> arguments,
  ) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: directory.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) return result.stdout as String;

    throw LicenseGateException(
      'git ${arguments.first} failed: ${(result.stderr as String).trim()}',
    );
  }
}

Future<void> _deleteTemporaryDirectory(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException {
    // The gate result matters more than best-effort cleanup of its temp clone.
  }
}

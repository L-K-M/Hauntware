import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _recordStart = '<!-- SEANCE_PIN_AUDIT_V3:START -->';
const _recordEnd = '<!-- SEANCE_PIN_AUDIT_V3:END -->';
const _legacyRecordStart = '<!-- SEANCE_PIN_AUDIT_V2:START -->';
const _legacyRecordEnd = '<!-- SEANCE_PIN_AUDIT_V2:END -->';
const _refreshHint =
    'review `scripts/audit-seance-pin.sh --print-findings`, then run '
    'scripts/audit-seance-pin.sh --write-record';
const _portsPath = 'docs/PORTS.md';
const _successExitCode = 0;
const _failureExitCode = 1;
const _noMatchesExitCode = 1;
const _shaLength = 40;
const _missingEmailMarker = '(no-email)';
const _gitlinkModePrefix = '160000 ';
const _seanceComponent = 'seance';

const _seancePackages = {'seance_core', 'seance_protocol'};
const _dependencySections = {
  'dependencies',
  'dev_dependencies',
  'dependency_overrides',
};
const _ignoredDirectories = {'.dart_tool', '.git', 'build'};
const _vendoredComponents = {
  'third_party',
  'third-party',
  'vendor',
  'vendors',
  'node_modules',
  'ext',
  'external',
  'deps',
  'Pods',
  'packages',
};
const _companionPatterns = {
  'co-authored-by',
  'signed-off-by',
  'reported-by',
  'helped-by',
  'reviewed-by',
  'tested-by',
  'suggested-by',
  'co-developed-by',
  'acked-by',
  'mentored-by',
};
const _licensePatterns = {
  'copyright',
  'spdx',
  'apache license',
  'gnu general',
  'permission is hereby granted',
  'redistribution and use',
  'mozilla public',
  'creative commons',
  'public domain',
  'apache-2',
  'bsd-2',
  'bsd-3',
  'mpl-2',
  '"mit"',
  '"isc"',
  'licen[cs]e',
};

final _shaPattern = RegExp(r'^[0-9a-f]{40}$');
final _emailPattern = RegExp(r'<([^<>]*@[^<>]*)>');
final _byAttributionPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_-]*-by:[ \t]+\S.*$',
  caseSensitive: false,
);
final _emailAttributionPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_-]*:[ \t]+\S.*<[^<>]*@[^<>]*>[ \t]*$',
);

enum _OutputMode { verify, printRecord, printFindings, writeRecord }

/// Runs the deterministic Séance local-source audit command.
Future<int> runSeancePinAudit(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    final worktree = await _worktreeRoot(options.root);
    final sources = _readLockedSources(options.root, worktree);
    _verifyManifestSources(options.root, worktree, sources);

    final evidence = await _collectEvidence(options, worktree, sources);
    final record = _renderRecord(sources, evidence);

    if (options.outputMode == _OutputMode.printRecord) {
      stdout.write(record);
      return _successExitCode;
    }
    if (options.outputMode == _OutputMode.printFindings) {
      stdout.write(evidence.renderFindings());
      return _successExitCode;
    }
    if (options.outputMode == _OutputMode.writeRecord) {
      _writeRecord(options.root, record);
      return _successExitCode;
    }

    _verifyRecord(options.root, record);
    stdout.writeln('Séance source audit matches $_portsPath');
    return _successExitCode;
  } on _AuditFailure catch (error) {
    stderr.writeln('Séance source audit failed: ${error.message}');
    return _failureExitCode;
  } on FormatException catch (error) {
    stderr.writeln('Séance source audit failed: ${error.message}');
    return _failureExitCode;
  }
}

/// The scan root must sit inside a Git worktree; the audited component tree
/// and lineage both come from that worktree's history.
Future<Directory> _worktreeRoot(Directory root) async {
  final result = await Process.run(
    'git',
    ['-C', root.path, '--no-replace-objects', 'rev-parse', '--show-toplevel'],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw _AuditFailure('scan root is not inside a Git worktree: ${root.path}');
  }
  final toplevel = p.normalize(
    await Directory('${result.stdout}'.trim()).resolveSymbolicLinks(),
  );
  final resolvedRoot = p.normalize(await root.resolveSymbolicLinks());
  if (resolvedRoot != toplevel && !p.isWithin(toplevel, resolvedRoot)) {
    throw _AuditFailure('scan root escapes its Git worktree: ${root.path}');
  }

  final shallow = await Process.run(
    'git',
    [
      '-C',
      toplevel,
      '--no-replace-objects',
      'rev-parse',
      '--is-shallow-repository',
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (shallow.stdout.trim() == 'true') {
    throw _AuditFailure('audit requires a non-shallow worktree: ${root.path}');
  }

  return Directory(toplevel);
}

Future<_Evidence> _collectEvidence(
  _Options options,
  Directory worktree,
  List<_LocalSource> sources,
) async {
  final components = <String>{
    for (final source in sources) source.componentRel,
  }.toList()..sort();

  final audits = <_ComponentEvidence>[];
  for (final componentRel in components) {
    final sourcesInComponent = sources
        .where((source) => source.componentRel == componentRel)
        .toList();
    await _verifyComponent(worktree, componentRel, sourcesInComponent);
    audits.add(await _auditComponent(worktree, componentRel));
  }

  return _Evidence(audits);
}

/// The audited surface is the committed component tree at HEAD, so the
/// worktree must not drift from it: an uncommitted change under the
/// component is exactly the ambiguity the record cannot certify.
Future<void> _verifyComponent(
  Directory worktree,
  String componentRel,
  List<_LocalSource> sources,
) async {
  final tree = await _runGit(worktree, [
    'rev-parse',
    '--verify',
    'HEAD:$componentRel',
  ]);
  if (!_shaPattern.hasMatch(tree.trim())) {
    throw _AuditFailure('HEAD does not contain the $componentRel component');
  }

  for (final source in sources) {
    final manifest = File(p.join(worktree.path, source.depRel, 'pubspec.yaml'));
    if (!manifest.existsSync()) {
      throw _AuditFailure(
        '${source.package} resolves to ${source.depRel} without a pubspec',
      );
    }
    final document = loadYaml(manifest.readAsStringSync());
    final name = document is YamlMap ? document['name']?.toString() : null;
    if (name != source.package) {
      throw _AuditFailure(
        '${source.package} resolves to ${source.depRel} whose package is '
        '$name',
      );
    }
  }

  final status = await _runGit(worktree, [
    'status',
    '--porcelain=v1',
    '--untracked-files=all',
    '--',
    componentRel,
  ]);
  if (status.trim().isNotEmpty) {
    throw _AuditFailure('the $componentRel component has uncommitted changes');
  }
}

/// Séance lineage inside the monorepo has two eras: post-import commits
/// touching `seance/` and the imported standalone history. Subtree merges
/// that introduced or refreshed the component carry the standalone tip as
/// an extra parent; each tip's ancestry is the component's own history.
Future<List<String>> _lineageTips(
  Directory worktree,
  String componentRel,
) async {
  final merges = await _runGit(worktree, [
    'log',
    '--merges',
    '--format=%H',
    'HEAD',
    '--',
    '$componentRel/',
  ]);
  final tips = <String>{};
  for (final merge in _nonEmptyLines(merges)) {
    final parents = await _runGit(worktree, [
      'rev-list',
      '--parents',
      '-n',
      '1',
      merge,
    ]);
    final fields = parents.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    for (final parent in fields.skip(2)) {
      // A standalone tip predates the monorepo prefix. A merged branch
      // carries the prefix; its commits are already in the post-import
      // log, and counting it would change the record on every such merge.
      final prefixed = await _runGit(
        worktree,
        ['rev-parse', '--verify', '--quiet', '$parent:$componentRel'],
        acceptedExitCodes: {_successExitCode, _noMatchesExitCode},
      );
      if (prefixed.trim().isEmpty) tips.add(parent);
    }
  }

  return tips.toList()..sort();
}

/// Runs `git log` over both lineage eras and returns the unioned output.
/// The standalone tips take no pathspec — their trees predate the
/// monorepo prefix — while post-import commits are selected by the
/// component path.
Future<String> _lineageLog(
  Directory worktree,
  String componentRel,
  List<String> tips,
  List<String> arguments,
) async {
  final imported = tips.isEmpty
      ? ''
      : await _runGit(worktree, [...arguments, ...tips]);
  final postImport = await _runGit(worktree, [
    ...arguments,
    'HEAD',
    '--',
    '$componentRel/',
  ]);

  return '$imported\n$postImport';
}

Future<_ComponentEvidence> _auditComponent(
  Directory worktree,
  String componentRel,
) async {
  final tips = await _lineageTips(worktree, componentRel);
  final treeRevision = (await _runGit(worktree, [
    'rev-parse',
    '--verify',
    'HEAD:$componentRel',
  ])).trim();

  final identity = await _identityAudit(worktree, componentRel, tips);
  final companion = await _companionAudit(
    worktree,
    componentRel,
    tips,
    identity,
  );
  final license = await _licenseAudit(worktree, componentRel);
  final tree = await _treeAudit(worktree, componentRel);
  final vendored = _vendoredPaths(tree);
  final gitlinks = _gitlinks(tree);
  if (gitlinks.isNotEmpty) {
    throw _AuditFailure(
      'component $componentRel contains gitlinks requiring a separate audit',
    );
  }
  final pinpoints = await _pinpointAudit(
    worktree,
    componentRel,
    tips,
    identity,
    companion.orphans,
  );

  return _ComponentEvidence(
    componentRel: componentRel,
    treeRevision: treeRevision,
    lineageTips: tips,
    identity: identity,
    companion: companion.output,
    companionOrphans: companion.orphans,
    license: license,
    tree: tree,
    vendored: vendored,
    gitlinks: gitlinks,
    pinpoints: pinpoints,
  );
}

Future<String> _identityAudit(
  Directory worktree,
  String componentRel,
  List<String> tips,
) async {
  const logOptions = [
    '-c',
    'log.mailmap=false',
    '-c',
    'i18n.logOutputEncoding=utf-8',
    'log',
  ];
  // Author and committer lines count whatever the name contains;
  // trailers count only as attributions. Other trailers (a
  // `Codex-Session:` id, say) are per-commit noise that would change the
  // record without any change in provenance.
  final people = await _lineageLog(worktree, componentRel, tips, [
    ...logOptions,
    '--format=%an <%ae>%n%cn <%ce>',
  ]);
  final trailers = await _lineageLog(worktree, componentRel, tips, [
    ...logOptions,
    '--format=%(trailers)',
  ]);

  return _sortUnique(
    [
      ..._nonEmptyLines(people),
      ..._nonEmptyLines(trailers).where(_isAttribution),
    ].join('\n'),
  );
}

Future<_CompanionEvidence> _companionAudit(
  Directory worktree,
  String componentRel,
  List<String> tips,
  String identity,
) async {
  final result = await _lineageLog(worktree, componentRel, tips, [
    '-c',
    'grep.patternType=basic',
    '-c',
    'log.mailmap=false',
    '-c',
    'i18n.logOutputEncoding=utf-8',
    'log',
    '-i',
    for (final pattern in _companionPatterns) '--grep=$pattern',
    r'--grep=<[^>]*@[^>]*>',
    '--format=%H %an <%ae>',
  ]);
  final identityAttributions = identity
      .split('\n')
      .where(_isAttribution)
      .map(_normalizeAttribution)
      .toSet();
  final orphans = <String>[];

  final summaries = _sortUnique(result);
  for (final summary in _nonEmptyLines(summaries)) {
    final commit = summary.substring(0, _shaLength);
    final message = await _runGit(worktree, [
      '-c',
      'log.mailmap=false',
      '-c',
      'i18n.logOutputEncoding=utf-8',
      'show',
      '-s',
      '--format=%B',
      commit,
    ]);
    for (final line in message.split('\n')) {
      final attribution = line.trimRight();
      if (!_isAttribution(attribution)) continue;
      if (identityAttributions.contains(_normalizeAttribution(attribution))) {
        continue;
      }

      final email =
          _emailPattern.firstMatch(attribution)?.group(1) ??
          _missingEmailMarker;
      orphans.add('$email\t$commit\t$attribution');
    }
  }

  return _CompanionEvidence(
    _sortUnique(result),
    _sortUnique(orphans.join('\n')),
  );
}

Future<String> _licenseAudit(Directory worktree, String componentRel) async {
  final result = await _runGit(
    worktree,
    [
      '-c',
      'grep.patternType=basic',
      '-c',
      'core.quotepath=false',
      'grep',
      '-I',
      '-i',
      for (final pattern in _licensePatterns) ...['-e', pattern],
      'HEAD',
      '--',
      '$componentRel/',
    ],
    acceptedExitCodes: {_successExitCode, _noMatchesExitCode},
  );

  return _normalize(result);
}

Future<String> _treeAudit(Directory worktree, String componentRel) async {
  final result = await _runGit(worktree, [
    '-c',
    'core.quotepath=false',
    'ls-tree',
    '-r',
    'HEAD:$componentRel',
  ]);

  return _normalize(result);
}

String _vendoredPaths(String tree) {
  final matches = <String>[];
  for (final line in _nonEmptyLines(tree)) {
    final separator = line.indexOf('\t');
    if (separator < 0) continue;

    final path = line.substring(separator + 1);
    final segments = p.posix.split(path);
    // The component's own top-level packages/ holds its first-party
    // packages (seance_core, seance_protocol, ...), not vendored code;
    // a vendoring directory anywhere below still counts.
    final components =
        (segments.first == 'packages' ? segments.skip(1) : segments).toSet();
    if (components.intersection(_vendoredComponents).isEmpty) continue;

    matches.add(path);
  }

  return matches.join('\n');
}

String _gitlinks(String tree) => _nonEmptyLines(
  tree,
).where((line) => line.startsWith(_gitlinkModePrefix)).join('\n');

Future<String> _pinpointAudit(
  Directory worktree,
  String componentRel,
  List<String> tips,
  String identity,
  String orphans,
) async {
  final emails =
      _emailPattern.allMatches(identity).map((match) => match.group(1)!).toSet()
        ..addAll(
          _nonEmptyLines(orphans)
              .map((line) => line.split('\t').first)
              .where((email) => email != _missingEmailMarker),
        );
  final sortedEmails = emails.toList()..sort();
  final lines = <String>[];

  for (final email in sortedEmails) {
    final escaped = _escapeBasicExpression(email);
    final commits = <String>[];

    // Git ANDs different limiting categories, so union three searches.
    for (final limiter in [
      '--author=$escaped',
      '--committer=$escaped',
      '--grep=$escaped',
    ]) {
      final result = await _lineageLog(worktree, componentRel, tips, [
        '-c',
        'grep.patternType=basic',
        '-c',
        'log.mailmap=false',
        '-c',
        'i18n.logOutputEncoding=utf-8',
        'log',
        '-i',
        limiter,
        '--format=%H',
      ]);
      commits.addAll(_nonEmptyLines(result));
    }

    for (final commit in _sortUnique(commits.join('\n')).split('\n')) {
      if (commit.isEmpty) continue;
      lines.add('$email\t$commit');
    }
  }

  for (final orphan in _nonEmptyLines(orphans)) {
    final fields = orphan.split('\t');
    if (fields.first != _missingEmailMarker) continue;

    final attribution = fields.skip(2).join('\t');
    final escaped = _escapeBasicExpression(attribution);
    final result = await _lineageLog(worktree, componentRel, tips, [
      '-c',
      'grep.patternType=basic',
      '-c',
      'log.mailmap=false',
      '-c',
      'i18n.logOutputEncoding=utf-8',
      'log',
      '-i',
      '--grep=$escaped',
      '--format=%H',
    ]);
    for (final commit in _nonEmptyLines(result)) {
      lines.add('$attribution\t$commit');
    }
  }

  return _sortUnique(lines.join('\n'));
}

String _escapeBasicExpression(String value) {
  final output = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    final edgeAnchor =
        (index == 0 && character == '^') ||
        (index == value.length - 1 && character == r'$');
    if (edgeAnchor ||
        character == r'\' ||
        character == '.' ||
        character == '[' ||
        character == '*') {
      output.write(r'\');
    }
    output.write(character);
  }

  return output.toString();
}

String _normalizeAttribution(String value) {
  final separator = value.indexOf(':');
  if (separator < 0) return value;

  final key = value.substring(0, separator).toLowerCase();
  final attribution = value.substring(separator + 1).trimLeft();
  return '$key: $attribution';
}

bool _isAttribution(String value) =>
    _byAttributionPattern.hasMatch(value) ||
    _emailAttributionPattern.hasMatch(value);

/// Séance sources are the locked `path` dependencies that resolve inside
/// this worktree's `seance/` component. Any other source — a git pin, a
/// hosted version, an SDK dep, or a path that escapes the worktree or the
/// component — is a fail-closed violation, never an ambiguity.
List<_LocalSource> _readLockedSources(Directory root, Directory worktree) {
  final sources = <_LocalSource>{};
  for (final file in _findFiles(root, 'pubspec.lock')) {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is! YamlMap) continue;
    final packages = yaml['packages'];
    if (packages is! YamlMap) continue;

    for (final entry in packages.entries) {
      final package = entry.key?.toString() ?? '';
      final details = entry.value;
      if (details is! YamlMap) continue;
      final source = details['source']?.toString() ?? '';
      if (source == 'git') {
        final description = details['description'];
        final url = description is YamlMap
            ? description['url']?.toString() ?? ''
            : '';
        if (!_isSeanceDependency(package, url)) continue;

        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} pins $package to an '
          'external git source',
        );
      }
      if (source != 'path') {
        if (_isSeancePackage(package)) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} resolves $package '
            'from an unexpected source',
          );
        }
        continue;
      }

      final description = details['description'];
      if (description is! YamlMap) continue;
      final resolved = _resolveLockPath(file, description);
      if (resolved == null) {
        if (_isSeancePackage(package)) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} resolves $package '
            'without a usable path',
          );
        }
        continue;
      }
      final withinWorktree = _isWithinWorktree(worktree, resolved);
      final componentRel = withinWorktree
          ? _componentOf(worktree, resolved)
          : null;
      if (!_isSeancePackage(package) && componentRel != _seanceComponent) {
        continue;
      }
      if (!withinWorktree) {
        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} resolves $package '
          'outside the worktree',
        );
      }
      if (componentRel != _seanceComponent) {
        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} resolves $package '
          'outside the $_seanceComponent component',
        );
      }

      sources.add(
        _LocalSource(
          package: package,
          depRel: p.posix.joinAll(
            p.split(p.relative(resolved, from: worktree.path)),
          ),
          componentRel: componentRel!,
        ),
      );
    }
  }

  if (sources.isEmpty) {
    throw const _AuditFailure('no locked Séance source found');
  }

  final sorted = sources.toList()
    ..sort((left, right) {
      final byPackage = left.package.compareTo(right.package);
      if (byPackage != 0) return byPackage;
      return left.depRel.compareTo(right.depRel);
    });
  return sorted;
}

String? _resolveLockPath(File lock, YamlMap description) {
  final path = description['path']?.toString();
  if (path == null || path.isEmpty) return null;
  final relative = description['relative'];
  if (p.isAbsolute(path)) return p.normalize(path);
  // `relative: false` marks an absolute path; a non-absolute value here is
  // not a usable resolution.
  if (relative is bool && !relative) return null;

  return p.normalize(p.join(lock.parent.path, path));
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

void _verifyManifestSources(
  Directory root,
  Directory worktree,
  List<_LocalSource> sources,
) {
  var declarationCount = 0;
  for (final file in _findFiles(root, 'pubspec.yaml')) {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is! YamlMap) continue;

    for (final sectionName in _dependencySections) {
      final section = yaml[sectionName];
      if (section is! YamlMap) continue;

      for (final entry in section.entries) {
        final package = entry.key?.toString() ?? '';
        final details = entry.value;
        if (details is! YamlMap) {
          if (_isSeancePackage(package)) {
            throw _AuditFailure(
              '${p.relative(file.path, from: root.path)} declares $package '
              'without a path source',
            );
          }
          continue;
        }

        final git = details['git'];
        if (git != null) {
          final url = git is YamlMap
              ? git['url']?.toString() ?? ''
              : git?.toString() ?? '';
          if (!_isSeanceDependency(package, url)) continue;

          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} declares $package '
            'on an external git source',
          );
        }

        final declaredPath = details['path']?.toString();
        if (declaredPath == null || declaredPath.isEmpty) {
          if (_isSeancePackage(package)) {
            throw _AuditFailure(
              '${p.relative(file.path, from: root.path)} declares $package '
              'without a path source',
            );
          }
          continue;
        }
        final resolved = p.normalize(
          p.isAbsolute(declaredPath)
              ? declaredPath
              : p.join(file.parent.path, declaredPath),
        );
        final withinWorktree = _isWithinWorktree(worktree, resolved);
        final componentRel = withinWorktree
            ? _componentOf(worktree, resolved)
            : null;
        if (!_isSeancePackage(package) && componentRel != _seanceComponent) {
          continue;
        }
        if (!withinWorktree) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} declares $package '
            'outside the worktree',
          );
        }
        if (componentRel != _seanceComponent) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} declares $package '
            'outside the $_seanceComponent component',
          );
        }

        declarationCount++;
        final lock = _resolvingLock(root, file);
        if (lock == null) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} has no resolving lock',
          );
        }
        final lockedSource = _lockedPackageSource(lock, package);
        final depRel = p.posix.joinAll(
          p.split(p.relative(resolved, from: worktree.path)),
        );
        final matches =
            lockedSource != null &&
            lockedSource.resolved == resolved &&
            sources.any(
              (source) => source.package == package && source.depRel == depRel,
            );
        if (matches) continue;

        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} manifest and lock '
          'Séance paths differ',
        );
      }
    }
  }

  if (declarationCount == 0) {
    throw const _AuditFailure('no Séance path dependency declared');
  }
}

File? _resolvingLock(Directory root, File manifest) {
  final adjacent = File(p.join(manifest.parent.path, 'pubspec.lock'));
  if (adjacent.existsSync()) return adjacent;

  var ancestor = manifest.parent.parent;
  while (p.isWithin(root.path, ancestor.path) ||
      p.equals(root.path, ancestor.path)) {
    final ancestorManifest = File(p.join(ancestor.path, 'pubspec.yaml'));
    final lock = File(p.join(ancestor.path, 'pubspec.lock'));
    if (ancestorManifest.existsSync() && lock.existsSync()) {
      final yaml = loadYaml(ancestorManifest.readAsStringSync());
      final workspace = yaml is YamlMap ? yaml['workspace'] : null;
      final relative = p.normalize(
        p.relative(manifest.parent.path, from: ancestor.path),
      );
      if (workspace is YamlList &&
          workspace
              .map((entry) => p.normalize(entry.toString()))
              .contains(relative)) {
        return lock;
      }
    }
    if (p.equals(root.path, ancestor.path)) break;

    ancestor = ancestor.parent;
  }

  return null;
}

_LockedPackageSource? _lockedPackageSource(File lock, String package) {
  final yaml = loadYaml(lock.readAsStringSync());
  if (yaml is! YamlMap) return null;
  final packages = yaml['packages'];
  if (packages is! YamlMap) return null;
  final details = packages[package];
  if (details is! YamlMap || details['source'] != 'path') return null;
  final description = details['description'];
  if (description is! YamlMap) return null;

  final resolved = _resolveLockPath(lock, description);
  if (resolved == null) return null;

  return _LockedPackageSource(resolved);
}

Iterable<File> _findFiles(Directory root, String name) sync* {
  for (final entity in root.listSync(followLinks: false)) {
    if (entity is File && p.basename(entity.path) == name) {
      yield entity;
      continue;
    }
    if (entity is! Directory) continue;
    if (_ignoredDirectories.contains(p.basename(entity.path))) continue;

    yield* _findFiles(entity, name);
  }
}

bool _isSeancePackage(String package) =>
    _seancePackages.contains(package) || package.startsWith('seance_');

bool _isSeanceDependency(String package, String url) {
  if (_isSeancePackage(package)) return true;

  final normalized = url.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return normalized.endsWith('/seance') || normalized.endsWith('/seance.git');
}

String _renderRecord(List<_LocalSource> sources, _Evidence evidence) {
  final buffer = StringBuffer()
    ..writeln(_recordStart)
    ..writeln('## Séance source audit')
    ..writeln()
    ..writeln('Deterministic local-source audit. Séance packages resolve')
    ..writeln('by path inside this worktree. The record binds provenance')
    ..writeln('over the component\'s full lineage (imported standalone')
    ..writeln('ancestry included): the people named as authors, committers')
    ..writeln('or attribution trailers, attributions that match none of')
    ..writeln('them, license and copyright lines, vendored paths and')
    ..writeln('gitlinks. Ordinary changes by known contributors leave it')
    ..writeln('unchanged; when it changes, provenance changed and needs')
    ..writeln('review. Sections are content-addressed by SHA-256; line')
    ..writeln('counts aid review. Use `--print-findings` to see them, with')
    ..writeln('the commit-level detail, without adding names to docs.')
    ..writeln();
  for (final source in sources) {
    buffer.writeln(
      '- Source: `${source.package}` at `${source.depRel}` '
      '(path dependency)',
    );
  }
  for (final audit in evidence.audits) {
    buffer.writeln('- Component: `${audit.componentRel}/` at `HEAD`');
    if (audit.lineageTips.isNotEmpty) {
      buffer.writeln(
        '- Lineage: ${audit.lineageTips.map((tip) => '`$tip`').join(', ')}',
      );
    }
  }
  for (final section in evidence.recordSections.entries) {
    buffer.writeln(
      '- ${section.key}: ${section.value.lineCount} lines; '
      '`${section.value.digest}`',
    );
  }
  buffer.writeln(_recordEnd);
  return buffer.toString();
}

void _verifyRecord(Directory root, String expected) {
  final file = File(p.join(root.path, _portsPath));
  if (!file.existsSync()) {
    throw const _AuditFailure('$_portsPath is missing the source audit record');
  }

  final contents = file.readAsStringSync();
  if (contents.contains(_legacyRecordStart)) {
    throw _AuditFailure(
      contents.contains(_recordStart)
          ? '$_portsPath still holds a V2 record beside the V3 one; '
                'delete the V2 block'
          : '$_portsPath holds a V2 record, which binds every commit; '
                '$_refreshHint to migrate it',
    );
  }
  final span = _recordSpan(contents, _recordStart, _recordEnd);
  final actual = '${contents.substring(span.$1, span.$2)}\n';
  if (actual == expected) return;

  final changed = _changedLabels(actual, expected);
  throw _AuditFailure(
    '$_portsPath record does not match '
    '(changed: ${changed.isEmpty ? 'record text' : changed.join(', ')}); '
    '$_refreshHint',
  );
}

/// The `- Label:` lines whose values differ between two records, in the
/// expected record's order, lower-cased for the failure message.
List<String> _changedLabels(String actual, String expected) {
  Map<String, String> fields(String record) => {
    for (final match in RegExp(
      r'^- ([^:]+): (.*)$',
      multiLine: true,
    ).allMatches(record))
      match[1]!: match[2]!,
  };

  final before = fields(actual);
  final after = fields(expected);
  return [
    for (final label in {...after.keys, ...before.keys})
      if (before[label] != after[label]) label.toLowerCase(),
  ];
}

/// Replaces the single recorded block in `$_portsPath` with the freshly
/// generated [record], preserving every byte around the markers. The
/// record file must already exist with exactly one marked block and must
/// resolve inside the audit root; every inconsistency fails before a
/// single byte is written.
void _writeRecord(Directory root, String record) {
  final file = File(p.join(root.path, _portsPath));
  if (!file.existsSync()) {
    throw const _AuditFailure('$_portsPath is missing the source audit record');
  }
  final resolvedRoot = root.resolveSymbolicLinksSync();
  final resolvedFile = file.resolveSymbolicLinksSync();
  if (!p.isWithin(resolvedRoot, resolvedFile)) {
    throw const _AuditFailure('$_portsPath resolves outside the audit root');
  }

  final contents = file.readAsStringSync();
  // A V2 block is replaced in place: the migration to V3.
  final span =
      !contents.contains(_recordStart) && contents.contains(_legacyRecordStart)
      ? _recordSpan(contents, _legacyRecordStart, _legacyRecordEnd)
      : _recordSpan(contents, _recordStart, _recordEnd);
  final actual = '${contents.substring(span.$1, span.$2)}\n';
  if (actual == record) {
    stdout.writeln('$_portsPath record already matches');
    return;
  }
  file.writeAsStringSync(
    contents.replaceRange(
      span.$1,
      span.$2,
      record.substring(0, record.length - 1),
    ),
  );
  stdout.writeln('$_portsPath record updated');
}

/// Byte offsets of the single [startMarker]…[endMarker] span, or a
/// failure when the file has zero or more than one marked record.
(int, int) _recordSpan(String contents, String startMarker, String endMarker) {
  final start = contents.indexOf(startMarker);
  final end = contents.indexOf(endMarker);
  final duplicateStart =
      start >= 0 && contents.indexOf(startMarker, start + 1) >= 0;
  final duplicateEnd = end >= 0 && contents.indexOf(endMarker, end + 1) >= 0;
  if (start < 0 || end < start || duplicateStart || duplicateEnd) {
    throw const _AuditFailure(
      '$_portsPath must contain one source audit record',
    );
  }

  return (start, end + endMarker.length);
}

/// Runs git in [worktree]; returns its standard output.
Future<String> _runGit(
  Directory worktree,
  List<String> arguments, {
  Set<int> acceptedExitCodes = const {_successExitCode},
}) => _run('git', [
  '-C',
  worktree.path,
  '--no-replace-objects',
  ...arguments,
], acceptedExitCodes: acceptedExitCodes);

Future<String> _run(
  String executable,
  List<String> arguments, {
  Set<int> acceptedExitCodes = const {_successExitCode},
}) async {
  final result = await Process.run(
    executable,
    arguments,
    environment: const {'LC_ALL': 'C'},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (!acceptedExitCodes.contains(result.exitCode)) {
    throw _AuditFailure(
      '$executable ${arguments.join(' ')} exited ${result.exitCode}: '
      '${(result.stderr as String).trim()}',
    );
  }

  return result.stdout as String;
}

String _normalize(String value) {
  var normalized = value.replaceAll('\r\n', '\n');
  while (normalized.endsWith('\n')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  return normalized;
}

String _sortUnique(String value) {
  final lines = _normalize(value).split('\n').toSet().toList()
    ..sort(_compareCBytes);
  return lines.join('\n');
}

int _compareCBytes(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final sharedLength = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < sharedLength; index++) {
    final difference = leftBytes[index] - rightBytes[index];
    if (difference != 0) return difference;
  }

  return leftBytes.length - rightBytes.length;
}

Iterable<String> _nonEmptyLines(String value) =>
    _normalize(value).split('\n').where((line) => line.isNotEmpty);

final class _Options {
  final Directory root;
  final _OutputMode outputMode;

  const _Options(this.root, this.outputMode);

  factory _Options.parse(List<String> arguments) {
    var root = Directory.current;
    var outputMode = _OutputMode.verify;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--root') {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a path');
        }
        root = Directory(p.absolute(arguments[++index]));
        continue;
      }
      if (argument == '--print-record') {
        if (outputMode != _OutputMode.verify) {
          throw const FormatException('choose one output mode');
        }
        outputMode = _OutputMode.printRecord;
        continue;
      }
      if (argument == '--print-findings') {
        if (outputMode != _OutputMode.verify) {
          throw const FormatException('choose one output mode');
        }
        outputMode = _OutputMode.printFindings;
        continue;
      }
      if (argument == '--write-record') {
        if (outputMode != _OutputMode.verify) {
          throw const FormatException('choose one output mode');
        }
        outputMode = _OutputMode.writeRecord;
        continue;
      }

      throw FormatException('unknown argument: $argument');
    }

    if (!root.existsSync()) {
      throw FormatException('root does not exist: ${root.path}');
    }

    return _Options(root, outputMode);
  }
}

final class _LocalSource {
  final String package;
  final String depRel;
  final String componentRel;

  const _LocalSource({
    required this.package,
    required this.depRel,
    required this.componentRel,
  });

  @override
  bool operator ==(Object other) =>
      other is _LocalSource &&
      other.package == package &&
      other.depRel == depRel &&
      other.componentRel == componentRel;

  @override
  int get hashCode => Object.hash(package, depRel, componentRel);
}

final class _LockedPackageSource {
  final String resolved;

  const _LockedPackageSource(this.resolved);
}

final class _Evidence {
  final List<_ComponentEvidence> audits;

  const _Evidence(this.audits);

  /// The record's sections, keyed by their label. Each is headed by the
  /// component path only: the tree id would change every section on any
  /// commit, which is exactly what the record must not bind.
  Map<String, _Section> get recordSections => {
    'Identity': _combine((audit) => audit.identity),
    'Unmatched attributions': _combine(
      (audit) => _unmatchedAttributions(audit.companionOrphans),
    ),
    'License scan': _combine((audit) => audit.license),
    'Vendored paths': _combine((audit) => audit.vendored),
    'Gitlinks': _combine((audit) => audit.gitlinks),
  };

  _Section _combine(String Function(_ComponentEvidence) select) {
    final buffer = StringBuffer();
    var lineCount = 0;
    for (final audit in audits) {
      final output = select(audit);
      buffer
        ..writeln(audit.componentRel)
        ..writeln(output);
      lineCount += _countLines(output);
    }
    return _Section(buffer.toString().trimRight(), lineCount);
  }

  /// Orphaned attributions without the commits that carry them
  /// (`email<TAB>commit<TAB>attribution` becomes `email<TAB>attribution`).
  static String _unmatchedAttributions(String orphans) => _sortUnique(
    _nonEmptyLines(orphans)
        .map((line) {
          final fields = line.split('\t');
          return [fields.first, ...fields.skip(2)].join('\t');
        })
        .join('\n'),
  );

  String renderFindings() {
    final buffer = StringBuffer();
    for (final audit in audits) {
      buffer.writeln(
        '[component]\n${audit.componentRel}@${audit.treeRevision}',
      );
      for (final section in audit.sections.entries) {
        buffer.writeln('[${section.key}]\n${section.value}');
      }
    }
    return buffer.toString();
  }
}

final class _ComponentEvidence {
  final String componentRel;
  final String treeRevision;
  final List<String> lineageTips;
  final String identity;
  final String companion;
  final String companionOrphans;
  final String license;
  final String tree;
  final String vendored;
  final String gitlinks;
  final String pinpoints;

  const _ComponentEvidence({
    required this.componentRel,
    required this.treeRevision,
    required this.lineageTips,
    required this.identity,
    required this.companion,
    required this.companionOrphans,
    required this.license,
    required this.tree,
    required this.vendored,
    required this.gitlinks,
    required this.pinpoints,
  });

  Map<String, String> get sections => {
    'identity': identity,
    'companion': companion,
    'companion-orphans': companionOrphans,
    'pinpoints': pinpoints,
    'license': license,
    'vendored': vendored,
    'gitlinks': gitlinks,
    'tree': tree,
  };
}

final class _Section {
  final String output;
  final int lineCount;

  const _Section(this.output, this.lineCount);

  String get digest => 'sha256:${sha256.convert(utf8.encode(output))}';
}

int _countLines(String output) =>
    output.isEmpty ? 0 : '\n'.allMatches(output).length + 1;

final class _CompanionEvidence {
  final String output;
  final String orphans;

  const _CompanionEvidence(this.output, this.orphans);
}

final class _AuditFailure implements Exception {
  final String message;

  const _AuditFailure(this.message);
}
